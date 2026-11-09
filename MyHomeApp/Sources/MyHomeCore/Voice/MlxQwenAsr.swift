// Optional MLX (Apple-silicon GPU) decode backend for the Qwen3-ASR ring,
// ported from Pop (QwenAsrMlxEngine.swift). It replaces ONLY the per-segment
// decode: Silero VAD, pre-roll, endpointing and the echo guard stay in
// SegmentingTranscriber. Selected by `speechQwenBackend`; any missing model or
// load failure falls back to the sherpa-onnx decoder.
import Foundation
import MLX
import MLXAudioSTT

public enum MlxQwenSpec {
    // allow-hardcode: community MLX conversion (Apache 2.0) Pop benchmarked
    // against the sherpa INT8 build; config data, nothing user-specific is sent.
    public static let modelRepo = "mlx-community/Qwen3-ASR-1.7B-8bit"
    public static let hubBaseURL = "https://huggingface.co"
    public static let directoryName = "qwenasr-mlx-8bit"
    public static let modelFiles = [
        "config.json", "generation_config.json", "preprocessor_config.json",
        "tokenizer_config.json", "chat_template.json", "vocab.json", "merges.txt",
        "model.safetensors.index.json", "model.safetensors",
    ]
    public static let approxDownloadMB = 2450
    /// Size floors: a truncated or HTML-error-page asset must not pass the gate.
    static let minWeightsBytes = 500 * 1024 * 1024
    static let minVocabBytes = 64 * 1024
    static let minMergesBytes = 64 * 1024
}

public enum MlxQwenStore {
    public static func ownDirectory() -> URL {
        SpeechModelStore.applicationSupport
            .appendingPathComponent(SpeechModelSpec.appSupportFolder, isDirectory: true)
            .appendingPathComponent(SpeechModelSpec.speechFolder, isDirectory: true)
            .appendingPathComponent(MlxQwenSpec.directoryName, isDirectory: true)
    }

    /// Pop's copy, searched read-only when `speechUsePopModels` is on.
    public static func popDirectory() -> URL {
        SpeechModelStore.applicationSupport
            .appendingPathComponent(SpeechModelSpec.popAppSupportFolder, isDirectory: true)
            .appendingPathComponent(MlxQwenSpec.directoryName, isDirectory: true)
    }

    public static func locate(usePop: Bool) -> URL? {
        if isInstalled(at: ownDirectory()) { return ownDirectory() }
        if usePop, isInstalled(at: popDirectory()) { return popDirectory() }
        return nil
    }

    public static func isInstalled(at dir: URL) -> Bool {
        func size(_ name: String) -> Int { SpeechModelStore.fileSize(dir.appendingPathComponent(name).path) }
        guard size("model.safetensors") >= MlxQwenSpec.minWeightsBytes,
              size("vocab.json") >= MlxQwenSpec.minVocabBytes,
              size("merges.txt") >= MlxQwenSpec.minMergesBytes,
              let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
        return true
    }

    /// Streams each file to a staging name next to its destination, then renames.
    public static func install() async throws {
        let dir = ownDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        AppLog.assistant.info("mlx speech model download start")
        for file in MlxQwenSpec.modelFiles {
            guard let url = URL(string: "\(MlxQwenSpec.hubBaseURL)/\(MlxQwenSpec.modelRepo)/resolve/main/\(file)") else {
                throw SpeechModelInstallError.badURL
            }
            let (location, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? fm.removeItem(at: location)
                throw SpeechModelInstallError.httpStatus(http.statusCode)
            }
            let destination = dir.appendingPathComponent(file)
            let staging = dir.appendingPathComponent(".partial-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            try fm.moveItem(at: location, to: staging)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: staging, to: destination)
        }
        AppLog.assistant.info("mlx speech model download done")
    }
}

/// Process-local model cache (loading maps ~2 GB of weights).
final class MlxQwenContext: @unchecked Sendable {
    static let shared = MlxQwenContext()
    private let lock = NSLock()
    private var cached: Qwen3ASRModel?
    private var cachedPath: String?

    private final class LoadBox: @unchecked Sendable { var model: Qwen3ASRModel? }

    /// Blocking load; callers run off the main thread under a deadline.
    func model(directory: URL) -> Qwen3ASRModel? {
        lock.lock()
        if let cached, cachedPath == directory.path { lock.unlock(); return cached }
        lock.unlock()
        let box = LoadBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.model = try await Qwen3ASRModel.fromModelDirectory(directory) }
            catch { AppLog.assistant.error("mlx speech model load failed: \(String(describing: error), privacy: .public)") }
            done.signal()
        }
        done.wait()
        guard let model = box.model else { return nil }
        // Compile the Metal kernels once per process, not on the first command.
        _ = model.generate(audio: MLXArray([Float](repeating: 0, count: SpeechModelSpec.sampleRate)))
        lock.lock(); cached = model; cachedPath = directory.path; lock.unlock()
        return model
    }
}

/// Decoder handle used by SegmentingTranscriber on the shared decode queue.
final class MlxQwenDecoder: OfflineSpeechDecoder, @unchecked Sendable {
    private let model: Qwen3ASRModel
    /// Hotwords go in the decoder's system prompt (space-joined, like Pop).
    private let context: String

    init?(directory: URL, hotwords: [String]) {
        guard MlxQwenStore.isInstalled(at: directory),
              let model = MlxQwenContext.shared.model(directory: directory) else { return nil }
        self.model = model
        self.context = hotwords.joined(separator: " ")
    }

    func decode(_ samples: [Float], sampleRate: Int) -> String {
        model.generate(audio: MLXArray(samples), context: context).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

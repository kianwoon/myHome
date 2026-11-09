// The sherpa-onnx side of the offline speech layer, ported from the Pop app
// (QwenAsrEngine.swift, SenseVoiceEngine.swift): model discovery + usability
// gate, the install/download flow, the process-local recognizer cache, and the
// Silero VAD / Qwen3-ASR / SenseVoice adapters behind SpeechEngine.swift's
// protocols. sherpa-onnx's Swift wrapper calls fatalError on a bad asset, so
// nothing here constructs a recognizer before `SpeechModelStore` validated it.
import Foundation
import SherpaOnnx

// MARK: - Model discovery

public enum SpeechModelSource: String, Sendable {
    case myHome, pop
}

public struct InstalledSpeechModel: Sendable, Equatable {
    public let kind: SpeechEngineKind
    public let directory: URL
    public let source: SpeechModelSource
}

public enum SpeechModelStore {
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// Where MyHome installs a model.
    public static func ownDirectory(_ kind: SpeechEngineKind) -> URL {
        applicationSupport
            .appendingPathComponent(SpeechModelSpec.appSupportFolder, isDirectory: true)
            .appendingPathComponent(SpeechModelSpec.speechFolder, isDirectory: true)
            .appendingPathComponent(SpeechModelSpec.directoryName(kind), isDirectory: true)
    }

    /// Where the Pop app installs the same model (read-only to MyHome).
    public static func popDirectory(_ kind: SpeechEngineKind) -> URL {
        applicationSupport
            .appendingPathComponent(SpeechModelSpec.popAppSupportFolder, isDirectory: true)
            .appendingPathComponent(SpeechModelSpec.directoryName(kind), isDirectory: true)
    }

    /// The first usable install: MyHome's own, then Pop's (when allowed).
    /// Uses the cheap gate (sizes + ONNX header) so it can run on the main
    /// actor; the full gate runs again off-main right before construction.
    public static func locate(_ kind: SpeechEngineKind, usePop: Bool) -> InstalledSpeechModel? {
        if isInstalled(kind, at: ownDirectory(kind), deep: false) {
            return InstalledSpeechModel(kind: kind, directory: ownDirectory(kind), source: .myHome)
        }
        if usePop, isInstalled(kind, at: popDirectory(kind), deep: false) {
            return InstalledSpeechModel(kind: kind, directory: popDirectory(kind), source: .pop)
        }
        return nil
    }

    // MARK: Asset paths (Pop's layout)

    static func vadURL(_ dir: URL) -> URL { dir.appendingPathComponent(SpeechModelSpec.vadFileName) }
    static func qwenConv(_ dir: URL) -> URL { dir.appendingPathComponent("conv_frontend.onnx") }
    static func qwenEncoder(_ dir: URL) -> URL { dir.appendingPathComponent("encoder.int8.onnx") }
    static func qwenDecoder(_ dir: URL) -> URL { dir.appendingPathComponent("decoder.int8.onnx") }
    static func qwenTokenizer(_ dir: URL) -> URL { dir.appendingPathComponent("tokenizer", isDirectory: true) }
    static func senseVoiceModel(_ dir: URL) -> URL { dir.appendingPathComponent("model.int8.onnx") }
    static func senseVoiceTokens(_ dir: URL) -> URL { dir.appendingPathComponent("tokens.txt") }

    /// USABILITY, not existence (Pop's install gate): size floors, the ONNX
    /// protobuf header byte, and parseable tokenizer tables.
    public static func isInstalled(_ kind: SpeechEngineKind, at dir: URL, deep: Bool = true) -> Bool {
        let vad = vadURL(dir).path
        guard fileSize(vad) >= SpeechModelSpec.minVadBytes, onnxHeaderLooksValid(vad) else { return false }
        switch kind {
        case .qwenAsr:
            let conv = qwenConv(dir).path, encoder = qwenEncoder(dir).path, decoder = qwenDecoder(dir).path
            let vocab = qwenTokenizer(dir).appendingPathComponent("vocab.json").path
            let merges = qwenTokenizer(dir).appendingPathComponent("merges.txt").path
            guard fileSize(conv) >= SpeechModelSpec.minQwenConvBytes,
                  fileSize(encoder) >= SpeechModelSpec.minQwenEncoderBytes,
                  fileSize(decoder) >= SpeechModelSpec.minQwenDecoderBytes,
                  fileSize(vocab) >= SpeechModelSpec.minQwenVocabBytes,
                  fileSize(merges) >= SpeechModelSpec.minQwenMergesBytes,
                  onnxHeaderLooksValid(conv), onnxHeaderLooksValid(encoder), onnxHeaderLooksValid(decoder)
            else { return false }
            guard deep else { return true }
            guard let vocabData = FileManager.default.contents(atPath: vocab),
                  let table = try? JSONSerialization.jsonObject(with: vocabData) as? [String: Any],
                  table.count >= SpeechModelSpec.minQwenVocabEntries,
                  let mergeText = try? String(contentsOfFile: merges, encoding: .utf8),
                  mergeText.split(whereSeparator: \.isNewline).count >= SpeechModelSpec.minQwenMergeLines
            else { return false }
            return true
        case .senseVoice:
            let model = senseVoiceModel(dir).path, tokens = senseVoiceTokens(dir).path
            guard fileSize(model) >= SpeechModelSpec.minSenseVoiceModelBytes,
                  fileSize(tokens) >= SpeechModelSpec.minSenseVoiceTokensBytes,
                  onnxHeaderLooksValid(model)
            else { return false }
            guard deep else { return true }
            guard let tokenText = try? String(contentsOfFile: tokens, encoding: .utf8)
            else { return false }
            return tokensParseable(tokenText)
        }
    }

    /// ONNX ModelProto starts with field 1 (`ir_version`, tag 0x08).
    static func onnxHeaderLooksValid(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let first = try? handle.read(upToCount: 1), first.count == 1 else { return false }
        return first[first.startIndex] == 0x08
    }

    static func fileSize(_ path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    /// `<token> <id>` per line; at least one pair and no malformed line.
    static func tokensParseable(_ text: String) -> Bool {
        var pairs = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let last = parts.last, Int(last) != nil else { return false }
            pairs += 1
        }
        return pairs > 0
    }
}

// MARK: - Install (Pop's download-as-UX flow)

public enum SpeechModelInstallError: Error, CustomStringConvertible {
    case badURL, httpStatus(Int), extract(Int32), missingFiles

    public var description: String {
        switch self {
        case .badURL: return "bad model URL"
        case .httpStatus(let code): return "download failed (HTTP \(code))"
        case .extract(let status): return "unpacking failed (tar exited \(status))"
        case .missingFiles: return "the archive did not contain the expected model files"
        }
    }
}

/// At most one in-flight install per engine; downloads into MyHome's own
/// directory (Pop's directory is never written).
public actor SpeechModelInstaller {
    public static let shared = SpeechModelInstaller()
    private var inFlight: [SpeechEngineKind: Task<Void, Error>] = [:]

    public func install(_ kind: SpeechEngineKind) async throws {
        if let existing = inFlight[kind] { return try await existing.value }
        let task = Task<Void, Error> { try await Self.download(kind) }
        inFlight[kind] = task
        defer { inFlight[kind] = nil }
        try await task.value
    }

    static func download(_ kind: SpeechEngineKind) async throws {
        let dir = SpeechModelStore.ownDirectory(kind)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = SpeechModelSpec.releaseBaseURL
        guard let archiveURL = URL(string: "\(base)/\(SpeechModelSpec.archiveName(kind)).\(SpeechModelSpec.archiveExtension)"),
              let vadURL = URL(string: "\(base)/\(SpeechModelSpec.vadFileName)") else {
            throw SpeechModelInstallError.badURL
        }
        AppLog.assistant.info("speech model download start engine=\(kind.rawValue, privacy: .public)")
        let archive = try await fetch(archiveURL)
        defer { try? fm.removeItem(at: archive) }
        let vad = try await fetch(vadURL)
        let vadDestination = SpeechModelStore.vadURL(dir)
        try? fm.removeItem(at: vadDestination)
        try fm.moveItem(at: vad, to: vadDestination)
        try extract(kind, archive: archive, into: dir)
        AppLog.assistant.info("speech model download done engine=\(kind.rawValue, privacy: .public)")
    }

    private static func fetch(_ url: URL) async throws -> URL {
        let (location, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            throw SpeechModelInstallError.httpStatus(http.statusCode)
        }
        // Move out of the system temp slot before it is reclaimed.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("myhome-speech-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: location, to: kept)
        return kept
    }

    /// Unpack into a staging directory on the same volume, then move the
    /// needed files into place (Pop's extract + locate).
    private static func extract(_ kind: SpeechEngineKind, archive: URL, into dir: URL) throws {
        let fm = FileManager.default
        let staging = dir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: SpeechModelSpec.tarPath)
        tar.arguments = ["-xjf", archive.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw SpeechModelInstallError.extract(tar.terminationStatus) }

        var found: [String: URL] = [:]
        if let walker = fm.enumerator(at: staging, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { found[url.lastPathComponent] = found[url.lastPathComponent] ?? url }
        }
        let moves: [(String, URL)]
        switch kind {
        case .qwenAsr:
            guard let conv = found["conv_frontend.onnx"] else { throw SpeechModelInstallError.missingFiles }
            moves = [("conv_frontend.onnx", SpeechModelStore.qwenConv(dir)),
                     ("encoder.int8.onnx", SpeechModelStore.qwenEncoder(dir)),
                     ("decoder.int8.onnx", SpeechModelStore.qwenDecoder(dir))]
            found["tokenizer"] = conv.deletingLastPathComponent().appendingPathComponent("tokenizer", isDirectory: true)
        case .senseVoice:
            moves = [("model.int8.onnx", SpeechModelStore.senseVoiceModel(dir)),
                     ("tokens.txt", SpeechModelStore.senseVoiceTokens(dir))]
        }
        for (name, destination) in moves {
            guard let source = found[name] else { throw SpeechModelInstallError.missingFiles }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: source, to: destination)
        }
        if kind == .qwenAsr, let tokenizer = found["tokenizer"] {
            guard fm.fileExists(atPath: tokenizer.path) else { throw SpeechModelInstallError.missingFiles }
            try? fm.removeItem(at: SpeechModelStore.qwenTokenizer(dir))
            try fm.moveItem(at: tokenizer, to: SpeechModelStore.qwenTokenizer(dir))
        }
        guard SpeechModelStore.isInstalled(kind, at: dir) else { throw SpeechModelInstallError.missingFiles }
    }
}

// MARK: - Recognizer cache

/// Process-local recognizer cache (Pop's *ContextCache): construction loads
/// hundreds of MB, so it is engine state, not listen state. ONE serial queue
/// serialises construction and every decode (recognizers are not
/// thread-safe). One recognizer per engine is kept; a new key (different
/// directory, hotwords or language) replaces it.
final class SherpaRecognizerCache: @unchecked Sendable {
    static let shared = SherpaRecognizerCache()
    let queue = DispatchQueue(label: "myhome.speech.decode", qos: .userInitiated)
    private let lock = NSLock()
    private var cached: [SpeechEngineKind: (key: String, recognizer: SherpaOnnxOfflineRecognizer)] = [:]

    /// Callers MUST have validated the directory with SpeechModelStore.
    func recognizer(kind: SpeechEngineKind, directory: URL, hotwords: String, language: String) -> SherpaOnnxOfflineRecognizer {
        let key = "\(directory.path)|\(hotwords)|\(language)"
        lock.lock(); defer { lock.unlock() }
        if let entry = cached[kind], entry.key == key { return entry.recognizer }
        cached[kind] = nil
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: SpeechModelSpec.sampleRate,
                                                 featureDim: SpeechModelSpec.featureDim)
        let recognizer: SherpaOnnxOfflineRecognizer
        switch kind {
        case .qwenAsr:
            var config = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: "",
                numThreads: SpeechModelSpec.inferenceThreads,
                provider: "cpu",
                debug: 0,
                qwen3Asr: sherpaOnnxOfflineQwen3ASRModelConfig(
                    convFrontend: SpeechModelStore.qwenConv(directory).path,
                    encoder: SpeechModelStore.qwenEncoder(directory).path,
                    decoder: SpeechModelStore.qwenDecoder(directory).path,
                    tokenizer: SpeechModelStore.qwenTokenizer(directory).path,
                    maxTotalLen: SpeechModelSpec.qwenMaxTotalLen,
                    maxNewTokens: SpeechModelSpec.qwenMaxNewTokens,
                    temperature: SpeechModelSpec.qwenTemperature,
                    topP: SpeechModelSpec.qwenTopP,
                    seed: SpeechModelSpec.qwenSeed,
                    hotwords: hotwords
                )
            ))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        case .senseVoice:
            var config = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: SpeechModelStore.senseVoiceTokens(directory).path,
                numThreads: SpeechModelSpec.inferenceThreads,
                provider: "cpu",
                debug: 0,
                modelType: "sense_voice",
                // Pop: ITN on — it gives SenseVoice punctuation and digits.
                senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                    model: SpeechModelStore.senseVoiceModel(directory).path,
                    language: language,
                    useInverseTextNormalization: true
                )
            ))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        }
        cached[kind] = (key, recognizer)
        return recognizer
    }
}

// MARK: - Adapters

final class SherpaDecoder: OfflineSpeechDecoder {
    private let recognizer: SherpaOnnxOfflineRecognizer
    /// Qwen3-ASR per-stream language name ("English"); empty = auto-detect.
    private let streamLanguage: String
    init(_ recognizer: SherpaOnnxOfflineRecognizer, streamLanguage: String = "") {
        self.recognizer = recognizer
        self.streamLanguage = streamLanguage
    }

    func decode(_ samples: [Float], sampleRate: Int) -> String {
        guard !streamLanguage.isEmpty else {
            return recognizer.decode(samples: samples, sampleRate: sampleRate).text
        }
        let stream = recognizer.createStream()
        stream.setOption(key: "language", value: streamLanguage)
        stream.acceptWaveform(samples: samples, sampleRate: sampleRate)
        recognizer.decode(stream: stream)
        return recognizer.getResult(stream: stream).text
    }
}

/// Silero VAD (Pop's dictation profile: one detector, no hysteresis).
final class SileroSegmenter: SpeechSegmenting {
    private let vad: SherpaOnnxVoiceActivityDetectorWrapper

    /// How far before the detection point sherpa-onnx starts a segment
    /// (voice-activity-detector.cc: 2 windows + min speech), plus one window
    /// of chunk slack — the pre-roll ring must reach past it.
    static func lookbackSamples(_ profile: VADProfile) -> Int {
        let minSpeech = Int(Double(profile.minSpeechSeconds) * Double(SpeechModelSpec.sampleRate))
        return SpeechModelSpec.vadLookbackWindows * SpeechModelSpec.vadWindowSize + minSpeech
    }

    init(vadPath: String, profile: VADProfile) {
        var config = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: vadPath,
                threshold: profile.threshold,
                minSilenceDuration: profile.minSilenceSeconds,
                minSpeechDuration: profile.minSpeechSeconds,
                windowSize: SpeechModelSpec.vadWindowSize,
                maxSpeechDuration: profile.maxSpeechSeconds
            ),
            sampleRate: Int32(SpeechModelSpec.sampleRate),
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )
        vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &config,
                                                      buffer_size_in_seconds: SpeechModelSpec.vadBufferSeconds)
    }

    /// Fed one Silero window at a time: handing the wrapper a large coalesced
    /// buffer (the decode queue lags the tap while a segment is decoding)
    /// truncated segments in testing, so the slice size is the model window.
    func accept(_ samples: [Float]) {
        var start = 0
        while start < samples.count {
            let end = min(start + SpeechModelSpec.vadWindowSize, samples.count)
            vad.acceptWaveform(samples: Array(samples[start..<end]))
            start = end
        }
    }
    var isSpeechDetected: Bool { vad.isSpeechDetected() }
    func flush() { vad.flush() }

    func popTimedSegment() -> TimedSpeechSegment? {
        guard !vad.isEmpty() else { return nil }
        let front = vad.front()
        let segment = TimedSpeechSegment(start: front.start, samples: front.samples)
        vad.pop()
        return segment
    }

    func popSegment() -> [Float]? {
        guard !vad.isEmpty() else { return nil }
        let samples = vad.front().samples
        vad.pop()
        return samples
    }
}

/// Builds a ready transcriber for one engine. Heavy (model load) — call off
/// the main thread and bound it with a deadline.
public enum SherpaTranscriberFactory {
    public struct Request: Sendable {
        public let model: InstalledSpeechModel
        public let profile: VADProfile
        public let hotwords: [String]
        public let localeIdentifier: String
        public var pinQwenLanguage = AppSettings.defaultSpeechQwenPinLanguage
        public var qwenBackend = AppSettings.defaultSpeechQwenBackend
        /// Directory of the installed MLX model when that backend is usable.
        public var mlxDirectory: URL?
    }

    static func make(_ request: Request,
                     onSegment: @escaping SegmentingTranscriber.SegmentHandler,
                     onActivity: @escaping SegmentingTranscriber.ActivityHandler) -> SegmentingTranscriber? {
        let dir = request.model.directory
        // Re-check right before construction: sherpa fatalErrors on bad assets.
        guard SpeechModelStore.isInstalled(request.model.kind, at: dir) else { return nil }
        let cache = SherpaRecognizerCache.shared
        let echoWords = request.hotwords
        let hotwords = request.model.kind == .qwenAsr ? HotwordList.format(request.hotwords) : ""
        let language = request.model.kind == .senseVoice ? SenseVoiceLanguage.pin(for: request.localeIdentifier) : ""
        let qwenLanguage = request.model.kind == .qwenAsr && request.pinQwenLanguage
            ? QwenLanguage.name(for: request.localeIdentifier) : ""
        // MLX backend: only for Qwen3-ASR, only when selected AND loadable;
        // otherwise the sherpa-onnx decoder below is used.
        var decoder: OfflineSpeechDecoder?
        if request.model.kind == .qwenAsr, request.qwenBackend == AppSettings.speechBackendMlx,
           let mlxDir = request.mlxDirectory {
            decoder = cache.queue.sync {
                MlxQwenDecoder(directory: mlxDir, hotwords: Array(request.hotwords.prefix(AppSettings.speechMaxHotwords)))
            }
        }
        let backendName = decoder == nil ? AppSettings.speechBackendOnnx : AppSettings.speechBackendMlx
        AppLog.assistant.info("qwen asr backend requested=\(request.qwenBackend, privacy: .public) active=\(backendName, privacy: .public)")
        if decoder == nil {
            let recognizer = cache.queue.sync {
                cache.recognizer(kind: request.model.kind, directory: dir, hotwords: hotwords, language: language)
            }
            decoder = SherpaDecoder(recognizer, streamLanguage: qwenLanguage)
        }
        let segmenter = SileroSegmenter(vadPath: SpeechModelStore.vadURL(dir).path, profile: request.profile)
        return SegmentingTranscriber(segmenter: segmenter, decoder: decoder!,
                                     sampleRate: SpeechModelSpec.sampleRate,
                                     preRollSeconds: request.profile.preRollSeconds,
                                     queue: cache.queue, onSegment: onSegment, onActivity: onActivity,
                                     vadLookbackSamples: SileroSegmenter.lookbackSamples(request.profile),
                                     ingestSliceSamples: SpeechModelSpec.vadWindowSize,
                                     engineName: request.model.kind.rawValue,
                                     rejectText: { text, seconds in
                                         HotwordEcho.isEcho(text, hotwords: echoWords, audioSeconds: seconds)
                                     })
    }
}

/// Qwen3-ASR hotwords: comma-separated (ASCII ','), so commas inside a name
/// are dropped; deduplicated case-insensitively and capped.
public enum HotwordList {
    /// Sorted case-insensitively so the string (the recognizer cache key) does
    /// not change when the device list is merely reordered.
    public static func format(_ phrases: [String], limit: Int = AppSettings.speechMaxHotwords) -> String {
        var seen = Set<String>()
        var out: [String] = []
        let ordered = phrases.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for phrase in ordered {
            let cleaned = phrase.replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            out.append(cleaned)
            if out.count >= limit { break }
        }
        return out.joined(separator: ",")
    }
}

/// SenseVoice's language pin derived from the voice locale (Pop pins rather
/// than trusting `auto`, which mislabels languages).
public enum SenseVoiceLanguage {
    static let supported: Set<String> = ["zh", "en", "ja", "ko", "yue"]
    static let fallback = "auto"

    public static func pin(for localeIdentifier: String) -> String {
        let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? ""
        return supported.contains(code) ? code : fallback
    }
}

/// Qwen3-ASR's per-stream language, as the English language name its prompt
/// expects ("English"). Empty (auto-detect) when the locale has no language.
public enum QwenLanguage {
    public static func name(for localeIdentifier: String) -> String {
        guard let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier else { return "" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? ""
    }
}

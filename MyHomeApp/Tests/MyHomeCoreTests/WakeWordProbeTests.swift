// Opt-in probe against the REAL keyword-spotting model. Skipped unless
// MYHOME_KWS_MODEL_DIR points at an unpacked sherpa-onnx KWS model and
// MYHOME_KWS_WAV_DIR at 16 kHz mono WAVs. Files named `wake-*.wav` must
// trigger; every other WAV must not (false-accept check, e.g. the app's own
// spoken replies rendered with `say -o reply.wav --data-format=LEI16@16000`).
import AVFoundation
import XCTest
@testable import MyHomeCore

final class WakeWordProbeTests: XCTestCase {
    private func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func testRealModelDetectsWakePhraseOnly() throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelDir = env["MYHOME_KWS_MODEL_DIR"], let wavDir = env["MYHOME_KWS_WAV_DIR"] else {
            throw XCTSkip("set MYHOME_KWS_MODEL_DIR and MYHOME_KWS_WAV_DIR")
        }
        let spotter = try SherpaWakeWordSpotter(
            directory: URL(fileURLWithPath: modelDir),
            config: .init(phrase: env["MYHOME_KWS_PHRASE"] ?? AppSettings.defaultWakeWordPhrase,
                          boost: env["MYHOME_KWS_BOOST"].flatMap(Double.init) ?? AppSettings.defaultWakeWordBoost,
                          threshold: env["MYHOME_KWS_THRESHOLD"].flatMap(Double.init) ?? AppSettings.defaultWakeWordThreshold,
                          keywordsOverride: env["MYHOME_KWS_KEYWORDS"]?.replacingOccurrences(of: "|", with: "\n"),
                          maxActivePaths: env["MYHOME_KWS_PATHS"].flatMap(Int.init) ?? WakeWordModelSpec.maxActivePaths,
                          numTrailingBlanks: env["MYHOME_KWS_BLANKS"].flatMap(Int.init) ?? WakeWordModelSpec.numTrailingBlanks))
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: wavDir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty)
        let chunk = env["MYHOME_KWS_CHUNK"].flatMap(Int.init) ?? SpeechModelSpec.sampleRate / 10
        let passes = env["MYHOME_KWS_PASSES"].flatMap(Int.init) ?? 1
        // Trailing silence lets the streaming model flush the last frames.
        let tail = [Float](repeating: 0, count: SpeechModelSpec.sampleRate)
        for file in files { for pass in 0..<passes {
            spotter.reset()
            let samples = try load(file) + tail
            var hits: [String] = []
            var start = 0
            while start < samples.count {
                if spotter.accept(Array(samples[start..<min(start + chunk, samples.count)])) {
                    hits.append(String(format: "%.1fs", Double(start) / Double(SpeechModelSpec.sampleRate)))
                }
                start += chunk
            }
            let hit = !hits.isEmpty
            let expected = file.lastPathComponent.hasPrefix("wake-")
            print("KWS PROBE \(file.lastPathComponent) pass=\(pass): hit=\(hit) expected=\(expected) hits=\(hits.count) at \(hits)")
            XCTAssertEqual(hit, expected, file.lastPathComponent)
        } }
    }

    /// Opt-in (network, ~33 MB): the real install path into a temp dir, then
    /// a spotter built from what it installed.
    func testRealInstallProducesUsableModel() async throws {
        guard ProcessInfo.processInfo.environment["MYHOME_KWS_INSTALL_TEST"] == "1" else {
            throw XCTSkip("set MYHOME_KWS_INSTALL_TEST=1")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kws-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await WakeWordModelInstaller.download(into: dir)
        XCTAssertTrue(WakeWordModelStore.isInstalled(at: dir))
        _ = try SherpaWakeWordSpotter(directory: dir, config: .init(phrase: AppSettings.defaultWakeWordPhrase,
                                                                    boost: AppSettings.defaultWakeWordBoost,
                                                                    threshold: AppSettings.defaultWakeWordThreshold))
    }
}

// Opt-in probe against the REAL installed sherpa-onnx models (Pop's or
// MyHome's install). Skipped unless MYHOME_REAL_SPEECH_DIR points at a folder
// of 16 kHz mono WAV files (e.g. rendered with `say -o x.wav
// --data-format=LEI16@16000 "turn off the study fan"`). Prints the raw
// transcript of every engine, with and without hotwords, plus what the parser
// makes of it — the evidence for transcript-shape regressions.
import AVFoundation
import XCTest
@testable import MyHomeCore

final class RealSpeechProbeTests: XCTestCase {
    private static let dirKey = "MYHOME_REAL_SPEECH_DIR"
    private static let hotwordsKey = "MYHOME_REAL_SPEECH_HOTWORDS"

    private func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func testPrintRealTranscripts() throws {
        guard let dir = ProcessInfo.processInfo.environment[Self.dirKey] else {
            throw XCTSkip("set \(Self.dirKey) to a folder of 16 kHz WAV files")
        }
        let hotwords = ProcessInfo.processInfo.environment[Self.hotwordsKey]?
            .split(separator: "|").map(String.init) ?? []
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
        let parser = VoiceCommandParser()
        let profile = AppSettings.speechVADProfile(from: UserDefaults(suiteName: UUID().uuidString)!)
        for kind in SpeechEngineKind.allCases {
            guard let model = SpeechModelStore.locate(kind, usePop: true) else { print("PROBE \(kind): not installed"); continue }
            for useHot in [false, true] where kind == .qwenAsr || !useHot {
                let words = useHot ? HotwordList.format(hotwords) : ""
                let language = kind == .senseVoice ? SenseVoiceLanguage.pin(for: "en_US") : ""
                let recognizer = SherpaRecognizerCache.shared.recognizer(kind: kind, directory: model.directory,
                                                                          hotwords: words, language: language)
                for file in files {
                    let samples = try load(file)
                    let start = Date()
                    let whole = recognizer.decode(samples: samples, sampleRate: SpeechModelSpec.sampleRate).text
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    // Through Silero + the transcriber, as the app runs it.
                    let collected = Collected()
                    let transcriber = SegmentingTranscriber(
                        segmenter: SileroSegmenter(vadPath: SpeechModelStore.vadURL(model.directory).path, profile: profile),
                        decoder: SherpaDecoder(recognizer), sampleRate: SpeechModelSpec.sampleRate,
                        preRollSeconds: profile.preRollSeconds, queue: DispatchQueue(label: "probe"),
                        onSegment: { collected.add($0) },
                        vadLookbackSamples: SileroSegmenter.lookbackSamples(profile),
                        ingestSliceSamples: SpeechModelSpec.vadWindowSize, engineName: kind.rawValue)
                    let chunk = Int(SpeechModelSpec.sampleRate) / 10
                    var i = 0
                    while i < samples.count { transcriber.append(samples: Array(samples[i..<min(i + chunk, samples.count)])); i += chunk }
                    let done = expectation(description: "flush")
                    transcriber.finish { done.fulfill() }
                    wait(for: [done], timeout: 30)
                    let joined = SegmentTextJoin.join(collected.all)
                    print("PROBE \(kind.rawValue) hot=\(useHot) file=\(file.lastPathComponent) ms=\(ms)")
                    print("PROBE   whole=\(String(reflecting: whole)) scalars=\(whole.unicodeScalars.map { String($0.value, radix: 16) }.prefix(8))")
                    print("PROBE   vad=\(String(reflecting: joined)) segments=\(collected.all.count)")
                    print("PROBE   parse(whole)=\(parser.parse(whole))")
                    print("PROBE   parse(vad)=\(parser.parse(joined))")
                }
            }
        }
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func add(_ text: String) { lock.lock(); parts.append(text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return parts }
}


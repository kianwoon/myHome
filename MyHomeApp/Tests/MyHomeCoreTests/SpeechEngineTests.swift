import AVFoundation
import XCTest
@testable import MyHomeCore

// MARK: - Test doubles

/// Energy-threshold stand-in for Silero: 512-sample frames, a frame whose RMS
/// exceeds `threshold` is speech; `minSilenceFrames` quiet frames close a
/// segment. Segments carry the audio from the first speech frame to the close.
private final class EnergySegmenter: SpeechSegmenting {
    let frame = 512
    let threshold: Float
    let minSilenceFrames: Int
    private var carry: [Float] = []
    private var current: [Float] = []
    private var silentRun = 0
    private var closed: [[Float]] = []
    private(set) var isSpeechDetected = false

    init(threshold: Float = 0.05, minSilenceFrames: Int = 10) {
        self.threshold = threshold
        self.minSilenceFrames = minSilenceFrames
    }

    func accept(_ samples: [Float]) {
        carry += samples
        while carry.count >= frame {
            let window = Array(carry.prefix(frame))
            carry.removeFirst(frame)
            let rms = (window.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame)).squareRoot()
            if rms > threshold {
                isSpeechDetected = true
                silentRun = 0
                current += window
            } else if isSpeechDetected {
                current += window
                silentRun += 1
                if silentRun >= minSilenceFrames { close() }
            }
        }
    }

    func popSegment() -> [Float]? { closed.isEmpty ? nil : closed.removeFirst() }

    func flush() { if isSpeechDetected { close() } }

    private func close() {
        closed.append(current)
        current = []
        silentRun = 0
        isSpeechDetected = false
    }
}

private final class RecordingDecoder: OfflineSpeechDecoder {
    private let lock = NSLock()
    private var _inputs: [[Float]] = []
    var fixedText: String?
    var inputs: [[Float]] { lock.lock(); defer { lock.unlock() }; return _inputs }

    func decode(_ samples: [Float], sampleRate: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        _inputs.append(samples)
        return fixedText ?? "segment \(_inputs.count)"
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [String] = []
    private var _activity: [Bool] = []
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return _texts }
    var activity: [Bool] { lock.lock(); defer { lock.unlock() }; return _activity }
    func add(_ text: String) { lock.lock(); _texts.append(text); lock.unlock() }
    func add(_ active: Bool) { lock.lock(); _activity.append(active); lock.unlock() }
}

private let rate = 16000

private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }

private func tone(_ seconds: Double, amplitude: Float = 0.5, hz: Float = 440) -> [Float] {
    (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * .pi * hz * Float($0) / Float(rate)) }
}

final class SegmentingTranscriberTests: XCTestCase {
    private func run(_ audio: [Float], decoder: RecordingDecoder, preRoll: Float = 0.5,
                     chunk: Int = 1024) -> Collector {
        let collector = Collector()
        let queue = DispatchQueue(label: "test.speech")
        let transcriber = SegmentingTranscriber(
            segmenter: EnergySegmenter(), decoder: decoder, sampleRate: rate, preRollSeconds: preRoll,
            queue: queue, onSegment: { collector.add($0) }, onActivity: { collector.add($0) })
        var index = 0
        while index < audio.count {
            transcriber.append(samples: Array(audio[index..<min(index + chunk, audio.count)]))
            queue.sync {}   // real-time pacing: the tap delivers one buffer at a time
            index += chunk
        }
        let done = expectation(description: "flushed")
        transcriber.finish { done.fulfill() }
        wait(for: [done], timeout: 10)
        return collector
    }

    func testTwoUtterancesBecomeTwoSegmentsWithPreRoll() {
        let decoder = RecordingDecoder()
        let audio = silence(1) + tone(0.6) + silence(0.6) + tone(0.5, hz: 660) + silence(0.6)
        let collector = run(audio, decoder: decoder)
        XCTAssertEqual(collector.texts, ["segment 1", "segment 2"])
        XCTAssertEqual(decoder.inputs.count, 2)
        // First segment: 500 ms pre-roll of observed silence is prepended.
        let first = decoder.inputs[0]
        XCTAssertGreaterThanOrEqual(first.count, Int(0.5 * Double(rate)) + Int(0.6 * Double(rate)) - 1024)
        XCTAssertTrue(first.prefix(4000).allSatisfy { $0 == 0 }, "pre-roll is the silence before the onset")
    }

    func testPreRollNeverReachesIntoThePreviousUtterance() {
        let decoder = RecordingDecoder()
        let audio = silence(1) + tone(0.6) + silence(0.4) + tone(0.5, hz: 660) + silence(0.6)
        _ = run(audio, decoder: decoder)
        XCTAssertEqual(decoder.inputs.count, 2)
        let second = decoder.inputs[1]
        // Everything before the second tone's onset must be silence (clamped).
        let onset = second.firstIndex { abs($0) > 0.05 } ?? 0
        XCTAssertLessThanOrEqual(onset, Int(0.4 * Double(rate)))
        XCTAssertTrue(second.prefix(onset).allSatisfy { abs($0) < 0.05 })
    }

    func testFinishFlushesAnOpenSegment() {
        let decoder = RecordingDecoder()
        let collector = run(silence(0.5) + tone(0.8), decoder: decoder)
        XCTAssertEqual(collector.texts, ["segment 1"])
        XCTAssertEqual(collector.activity, [true, false])
    }

    func testExactRepeatIsSuppressed() {
        let decoder = RecordingDecoder()
        decoder.fixedText = "turn on the lamp"
        let collector = run(silence(0.5) + tone(0.5) + silence(0.6) + tone(0.5) + silence(0.6), decoder: decoder)
        XCTAssertEqual(decoder.inputs.count, 2)
        XCTAssertEqual(collector.texts, ["turn on the lamp"])
    }

    func testSilenceOnlyYieldsNothing() {
        let decoder = RecordingDecoder()
        let collector = run(silence(2), decoder: decoder)
        XCTAssertTrue(collector.texts.isEmpty)
        XCTAssertTrue(decoder.inputs.isEmpty)
    }

    func testJoin() {
        XCTAssertEqual(SegmentTextJoin.join([" turn off ", "", "the lights"]), "turn off the lights")
    }
}

final class UtteranceEndpointerTests: XCTestCase {
    private let policy = EndpointPolicy(hangover: 0.6, noSpeechTimeout: 8, maxUtterance: 15)

    func testEndpointAfterHangoverFollowingASegment() {
        var e = UtteranceEndpointer(policy: policy, startedAt: 0)
        e.speechActivity(true, at: 1)
        XCTAssertEqual(e.evaluate(at: 3), .keepListening, "never ends mid-speech")
        e.speechActivity(false, at: 3)
        e.segmentDecoded(text: "turn off the lights", at: 3.2)
        XCTAssertEqual(e.evaluate(at: 3.5), .keepListening)
        XCTAssertEqual(e.evaluate(at: 3.9), .endpoint)
    }

    func testNewSpeechDuringHangoverKeepsListening() {
        var e = UtteranceEndpointer(policy: policy, startedAt: 0)
        e.speechActivity(true, at: 1)
        e.speechActivity(false, at: 2)
        e.segmentDecoded(text: "set the fan", at: 2.1)
        e.speechActivity(true, at: 2.4)
        XCTAssertEqual(e.evaluate(at: 4), .keepListening)
        e.speechActivity(false, at: 4)
        e.segmentDecoded(text: "to 2", at: 4.1)
        XCTAssertEqual(e.evaluate(at: 4.5), .keepListening)
        XCTAssertEqual(e.evaluate(at: 4.8), .endpoint)
    }

    func testUnfinishedTailWaitsLonger() {
        let p = EndpointPolicy(hangover: 1.2, noSpeechTimeout: 8, maxUtterance: 30, incompleteExtension: 1)
        var e = UtteranceEndpointer(policy: p, startedAt: 0)
        e.speechActivity(true, at: 1)
        e.speechActivity(false, at: 3)
        e.segmentDecoded(text: "turn on the lights and", at: 3.1)
        XCTAssertEqual(e.evaluate(at: 4.5), .keepListening)
        XCTAssertEqual(e.evaluate(at: 5.4), .endpoint)
        XCTAssertFalse(UtteranceEndpointer.looksIncomplete("Turn off the lights."))
        XCTAssertTrue(UtteranceEndpointer.looksIncomplete("Set the fan,"))
    }

    func testHeldOpenIgnoresPausesUntilCap() {
        var e = UtteranceEndpointer(policy: policy, startedAt: 0, heldOpen: true)
        e.speechActivity(true, at: 1)
        e.speechActivity(false, at: 2)
        e.segmentDecoded(text: "turn off study room fan.", at: 2.1)
        XCTAssertEqual(e.evaluate(at: 6), .keepListening, "a pause while the key is held is not an endpoint")
        XCTAssertEqual(e.evaluate(at: 14), .keepListening, "silence while held is not no-speech")
        XCTAssertEqual(e.evaluate(at: 15), .maxDuration)
    }

    func testEmptySegmentDoesNotEndpoint() {
        var e = UtteranceEndpointer(policy: policy, startedAt: 0)
        e.speechActivity(true, at: 1)
        e.speechActivity(false, at: 1.5)
        e.segmentDecoded(text: "  ", at: 1.6)
        XCTAssertEqual(e.evaluate(at: 3), .keepListening)
        XCTAssertEqual(e.evaluate(at: 9.6), .noSpeech)
    }

    func testNoSpeechTimeout() {
        let e = UtteranceEndpointer(policy: policy, startedAt: 10)
        XCTAssertEqual(e.evaluate(at: 17.9), .keepListening)
        XCTAssertEqual(e.evaluate(at: 18), .noSpeech)
    }

    func testMaxDurationCapsEvenDuringSpeech() {
        var e = UtteranceEndpointer(policy: policy, startedAt: 0)
        e.speechActivity(true, at: 0.5)
        XCTAssertEqual(e.evaluate(at: 15), .maxDuration)
    }
}

final class SpeechEngineChainTests: XCTestCase {
    private let all: (SpeechEngineKind) -> Bool = { _ in true }

    func testNaturalOrderAndEligibility() {
        let chain = SpeechEngineChain()
        XCTAssertEqual(chain.order(preferred: "", eligible: all), [.qwenAsr, .senseVoice])
        XCTAssertEqual(chain.order(preferred: "", eligible: { $0 == .senseVoice }), [.senseVoice])
        XCTAssertEqual(chain.order(preferred: "qwenAsr", eligible: { _ in false }), [])
    }

    func testPinLeadsAndUnknownPinIsIgnored() {
        let chain = SpeechEngineChain()
        XCTAssertEqual(chain.order(preferred: "senseVoice", eligible: all), [.senseVoice, .qwenAsr])
        XCTAssertEqual(chain.order(preferred: "appleSpeech", eligible: all), [.qwenAsr, .senseVoice])
        // An ineligible pin falls back to the chain.
        XCTAssertEqual(chain.order(preferred: "senseVoice", eligible: { $0 == .qwenAsr }), [.qwenAsr])
    }

    func testDeadEngineSortsLastAndRecovers() {
        let chain = SpeechEngineChain()
        chain.noteDead(.qwenAsr)
        XCTAssertEqual(chain.order(preferred: "qwenAsr", eligible: all), [.senseVoice, .qwenAsr])
        chain.noteGood(.qwenAsr)
        XCTAssertFalse(chain.isDead(.qwenAsr))
        XCTAssertEqual(chain.order(preferred: "", eligible: all), [.qwenAsr, .senseVoice])
    }

    func testLastGoodLeadsWithoutAPin() {
        let chain = SpeechEngineChain()
        chain.noteGood(.senseVoice)
        XCTAssertEqual(chain.order(preferred: "", eligible: all), [.senseVoice, .qwenAsr])
        chain.noteDead(.senseVoice)
        XCTAssertEqual(chain.order(preferred: "", eligible: all), [.qwenAsr, .senseVoice])
    }

    func testLivenessVerdict() {
        XCTAssertTrue(SpeechLiveness.isDead(hadResult: false, processedWindows: 0, audibleSeconds: 1.2, threshold: 1))
        XCTAssertFalse(SpeechLiveness.isDead(hadResult: false, processedWindows: 0, audibleSeconds: 0.5, threshold: 1))
        XCTAssertFalse(SpeechLiveness.isDead(hadResult: false, processedWindows: 3, audibleSeconds: 5, threshold: 1))
        XCTAssertFalse(SpeechLiveness.isDead(hadResult: true, processedWindows: 0, audibleSeconds: 5, threshold: 1))
    }
}

final class SpeechSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "SpeechSettingsTests-\(UUID())")! }

    func testDefaultsMatchPopDictationProfile() {
        let profile = AppSettings.speechVADProfile(from: defaults())
        XCTAssertEqual(profile, VADProfile(threshold: 0.5, minSilenceSeconds: 0.35, minSpeechSeconds: 0.25,
                                           maxSpeechSeconds: 10, preRollSeconds: 0.5))
        XCTAssertEqual(AppSettings.speechPreferredEngine(from: defaults()), SpeechEngineKind.qwenAsr.rawValue)
        XCTAssertTrue(AppSettings.speechEngineEnabled(.qwenAsr, from: defaults()))
        XCTAssertTrue(AppSettings.speechEngineEnabled(.senseVoice, from: defaults()))
        XCTAssertEqual(AppSettings.speechHandshakeTimeout(from: defaults()), 10)
    }

    func testValuesAreClampedToTheirRanges() {
        let d = defaults()
        d.set(5.0, forKey: AppSettings.speechVADThresholdKey)
        d.set(-1.0, forKey: AppSettings.speechVADMinSilenceKey)
        d.set(1000.0, forKey: AppSettings.speechModelLoadTimeoutKey)
        d.set(Double.nan, forKey: AppSettings.speechEndpointHangoverKey)
        d.set("junk", forKey: AppSettings.speechFlushTimeoutKey)
        let profile = AppSettings.speechVADProfile(from: d)
        XCTAssertEqual(Double(profile.threshold), AppSettings.speechVADThresholdRange.upperBound, accuracy: 1e-6)
        XCTAssertEqual(Double(profile.minSilenceSeconds), AppSettings.speechVADMinSilenceRange.lowerBound, accuracy: 1e-6)
        XCTAssertEqual(AppSettings.speechModelLoadTimeout(from: d), AppSettings.speechModelLoadTimeoutRange.upperBound)
        XCTAssertEqual(AppSettings.speechEndpointPolicy(from: d).hangover, AppSettings.defaultSpeechEndpointHangover)
        XCTAssertEqual(AppSettings.speechFlushTimeout(from: d), AppSettings.defaultSpeechFlushTimeout)
    }

    func testHotwordFormatting() {
        XCTAssertEqual(HotwordList.format(["Bedroom", "bedroom", "Fan, Study", "  ", "Desk  Lamp"]),
                       "Bedroom,Desk Lamp,Fan Study")
        XCTAssertEqual(HotwordList.format(["a", "b", "c"], limit: 2), "a,b")
    }

    func testSenseVoiceLanguagePin() {
        XCTAssertEqual(SenseVoiceLanguage.pin(for: "en-GB"), "en")
        XCTAssertEqual(SenseVoiceLanguage.pin(for: "zh_CN"), "zh")
        XCTAssertEqual(SenseVoiceLanguage.pin(for: "fr-FR"), "auto")
    }
}

final class SpeechModelStoreTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("speech-store-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testEmptyOrTruncatedInstallIsRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(SpeechModelStore.isInstalled(.qwenAsr, at: dir))
        XCTAssertFalse(SpeechModelStore.isInstalled(.senseVoice, at: dir))
        // An HTML error page saved under the model name is not an ONNX file.
        try Data("<html>404</html>".utf8).write(to: SpeechModelStore.senseVoiceModel(dir))
        try Data("a 1\n".utf8).write(to: SpeechModelStore.senseVoiceTokens(dir))
        XCTAssertFalse(SpeechModelStore.isInstalled(.senseVoice, at: dir))
        XCTAssertFalse(SpeechModelStore.onnxHeaderLooksValid(SpeechModelStore.senseVoiceModel(dir).path))
    }

    func testTokenTableParsing() {
        XCTAssertTrue(SpeechModelStore.tokensParseable("<blk> 0\nhello 1\n"))
        XCTAssertFalse(SpeechModelStore.tokensParseable("<html>\n"))
        XCTAssertFalse(SpeechModelStore.tokensParseable(""))
    }
}

/// Real inference against installed models (MyHome's or Pop's). Skipped when
/// no model is installed or the system `say` command cannot render audio.
final class SpeechModelInferenceTests: XCTestCase {
    private func spokenSamples(_ phrase: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@16000", phrase]
        do { try say.run() } catch { throw XCTSkip("say unavailable") }
        say.waitUntilExit()
        guard say.terminationStatus == 0, let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw XCTSkip("could not render speech") }
        try file.read(into: buffer)
        guard file.processingFormat.sampleRate == Double(rate), let channel = buffer.floatChannelData?[0] else {
            throw XCTSkip("unexpected audio format")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func transcribe(_ kind: SpeechEngineKind, _ phrase: String) throws -> String {
        guard let model = SpeechModelStore.locate(kind, usePop: true) else {
            throw XCTSkip("\(kind.label) model not installed")
        }
        let audio = silence(0.5) + (try spokenSamples(phrase)) + silence(1)
        let collector = Collector()
        let request = SherpaTranscriberFactory.Request(model: model, profile: AppSettings.speechVADProfile(from: UserDefaults(suiteName: "inference-\(UUID())")!),
                                                       hotwords: ["bedroom"], localeIdentifier: "en-US")
        guard let transcriber = SherpaTranscriberFactory.make(request, onSegment: { collector.add($0) },
                                                              onActivity: { _ in }) else {
            XCTFail("transcriber did not build")
            return ""
        }
        var index = 0
        while index < audio.count {
            transcriber.append(samples: Array(audio[index..<min(index + 1600, audio.count)]))
            index += 1600
        }
        let done = expectation(description: "flushed")
        transcriber.finish { done.fulfill() }
        wait(for: [done], timeout: 120)
        return SegmentTextJoin.join(collector.texts).lowercased()
    }

    func testSenseVoiceTranscribesASpokenCommand() throws {
        let text = try transcribe(.senseVoice, "Turn off the bedroom lights.")
        XCTAssertTrue(text.contains("bedroom"), "got: \(text)")
    }

    func testQwenAsrTranscribesASpokenCommand() throws {
        let text = try transcribe(.qwenAsr, "Turn off the bedroom lights.")
        XCTAssertTrue(text.contains("bedroom"), "got: \(text)")
    }
}

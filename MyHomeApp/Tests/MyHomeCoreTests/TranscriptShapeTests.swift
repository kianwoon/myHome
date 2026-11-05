// Regression tests for the transcript shapes the offline engines actually
// produce (captured with RealSpeechProbeTests on the installed Qwen3-ASR and
// SenseVoice models) and for the VAD onset bug that dropped the first word.
import XCTest
@testable import MyHomeCore

final class TranscriptShapeParserTests: XCTestCase {
    private let parser = VoiceCommandParser()

    private func command(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (DeviceQuery, DeviceCommand)? {
        if case .command(let query, let command) = parser.parse(text) { return (query, command) }
        XCTFail("not a command: \(text) → \(parser.parse(text))", file: file, line: line)
        return nil
    }

    func testSentenceCaseAndTrailingPeriod() {
        let parsed = command("Turn off the study fan.")
        XCTAssertEqual(parsed?.0.text, "study fan")
        XCTAssertEqual(parsed?.1, .power(false))
    }

    func testQwenSpelledNumbers() {
        XCTAssertEqual(command("Set the study fan speed to two.")?.1, .fanSpeed(2))
        XCTAssertEqual(command("Set the study fan to fifty percent.")?.1, .level(50))
        XCTAssertEqual(command("Set the lamp brightness to twenty five percent.")?.1, .level(25))
        XCTAssertEqual(command("Set the lamp to one hundred percent.")?.1, .level(100))
    }

    func testSenseVoiceDigitGluedToTo() {
        let parsed = command("Set the study fan speed to2.")
        XCTAssertEqual(parsed?.0.text, "study fan")
        XCTAssertEqual(parsed?.1, .fanSpeed(2))
        XCTAssertEqual(command("Set the study fan to 50%.")?.1, .level(50))
    }

    func testLeadingParticleAfterClippedVerb() {
        XCTAssertEqual(command("Off the study fan.")?.1, .power(false))
        XCTAssertEqual(command("On the bedroom lights.")?.0.text, "bedroom lights")
    }

    func testSmallSpelledNumberStillNamesADevice() {
        // "one" alone is not turned into a digit, so a name keeps its word.
        XCTAssertEqual(command("turn on the desk one")?.0.text, "desk one")
        // A hex-looking device suffix is never split.
        XCTAssertEqual(command("turn on briturn light 8e6d")?.0.text, "briturn light 8e6d")
    }
}

/// Mimics sherpa-onnx's Silero wrapper: speech is declared only after
/// `minSpeechFrames` loud frames, and the segment then starts 2 frames +
/// min-speech BEFORE the detection point, reporting that absolute start.
private final class LookbackSegmenter: SpeechSegmenting {
    let frame = 512
    let minSpeechFrames = 4
    let minSilenceFrames = 6
    private var history: [Float] = []
    private var carry: [Float] = []
    private var loudRun = 0
    private var quietRun = 0
    private var start: Int?
    private var closed: [TimedSpeechSegment] = []
    private(set) var isSpeechDetected = false

    func accept(_ samples: [Float]) {
        carry += samples
        while carry.count >= frame {
            let window = Array(carry.prefix(frame)); carry.removeFirst(frame)
            history += window
            let loud = window.map(abs).max() ?? 0 > 0.1
            if !isSpeechDetected {
                loudRun = loud ? loudRun + 1 : 0
                if loudRun >= minSpeechFrames {
                    isSpeechDetected = true
                    start = max(0, history.count - 2 * frame - minSpeechFrames * frame)
                    quietRun = 0
                }
            } else {
                quietRun = loud ? 0 : quietRun + 1
                if quietRun >= minSilenceFrames { close() }
            }
        }
    }

    func popSegment() -> [Float]? { popTimedSegment()?.samples }
    func popTimedSegment() -> TimedSpeechSegment? { closed.isEmpty ? nil : closed.removeFirst() }
    func flush() { if isSpeechDetected { close() } }

    private func close() {
        guard let start else { return }
        closed.append(TimedSpeechSegment(start: start, samples: Array(history[start...])))
        self.start = nil
        isSpeechDetected = false
        loudRun = 0
    }
}

private final class InputRecorder: OfflineSpeechDecoder {
    private let lock = NSLock()
    private var _inputs: [[Float]] = []
    var inputs: [[Float]] { lock.lock(); defer { lock.unlock() }; return _inputs }
    func decode(_ samples: [Float], sampleRate: Int) -> String {
        lock.lock(); _inputs.append(samples); lock.unlock()
        return "words"
    }
}

final class AlignedPreRollTests: XCTestCase {
    private let rate = 16000

    /// Every sample is unique, so a decoder input can be located exactly.
    private func audio(silence: Int, speech: Int, tail: Int) -> [Float] {
        let quiet = (0..<silence).map { Float($0) * 1e-7 }
        let loud = (0..<speech).map { 0.5 + Float($0) * 1e-6 }
        let after = (0..<tail).map { Float($0) * 1e-7 + 0.01 }
        return quiet + loud + after
    }

    private func transcribe(_ source: [Float], chunk: Int, lookback: Int, slice: Int) -> [Float] {
        let decoder = InputRecorder()
        let queue = DispatchQueue(label: "aligned.preroll")
        let transcriber = SegmentingTranscriber(segmenter: LookbackSegmenter(), decoder: decoder, sampleRate: rate,
                                                preRollSeconds: 0.25, queue: queue, onSegment: { _ in },
                                                vadLookbackSamples: lookback, ingestSliceSamples: slice)
        var index = 0
        while index < source.count {
            transcriber.append(samples: Array(source[index..<min(index + chunk, source.count)]))
            index += chunk
        }
        let done = expectation(description: "flushed")
        transcriber.finish { done.fulfill() }
        wait(for: [done], timeout: 10)
        return decoder.inputs.first ?? []
    }

    private func assertContiguous(_ input: [Float], in source: [Float], firstSpeech: Int,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let first = input.first, let at = source.firstIndex(of: first) else {
            return XCTFail("empty input", file: file, line: line)
        }
        XCTAssertEqual(input, Array(source[at..<(at + input.count)]), "decoder input repeats or skips audio", file: file, line: line)
        XCTAssertLessThanOrEqual(at, firstSpeech, "segment starts after the speech onset", file: file, line: line)
    }

    func testPreRollIsContiguousWithTheSegmentStart() {
        let source = audio(silence: rate, speech: rate, tail: rate / 2)
        let lookback = 3 * 512 + 4 * 512
        // Real-time small chunks and one coalesced burst give the same, contiguous input.
        let live = transcribe(source, chunk: 341, lookback: lookback, slice: 512)
        let burst = transcribe(source, chunk: source.count, lookback: lookback, slice: 512)
        assertContiguous(live, in: source, firstSpeech: rate)
        assertContiguous(burst, in: source, firstSpeech: rate)
        XCTAssertEqual(live, burst)
        XCTAssertGreaterThanOrEqual(rate - source.firstIndex(of: live[0])!, rate / 4, "a full pre-roll precedes the onset")
    }

    func testPrefixMath() {
        let snapshot = (0..<100).map(Float.init)          // absolute 900..<1000
        let out = AlignedPreRoll.prefix(snapshot, snapshotEnd: 1000, segmentStart: 960,
                                        observedSilenceSamples: 100, capacity: 20)
        XCTAssertEqual(out, (40..<60).map(Float.init), "ends exactly at the segment start")
        // Silence observed only since 980: nothing before 960 may be replayed.
        XCTAssertEqual(AlignedPreRoll.prefix(snapshot, snapshotEnd: 1000, segmentStart: 960,
                                             observedSilenceSamples: 20, capacity: 20), [])
        XCTAssertEqual(AlignedPreRoll.prefix(snapshot, snapshotEnd: 1000, segmentStart: 1010,
                                             observedSilenceSamples: 100, capacity: 20), [])
    }
}

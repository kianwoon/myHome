import XCTest
@testable import MyHomeCore

private final class FakeCapture: WakeAudioCapturing, @unchecked Sendable {
    var starts = 0, stops = 0
    var running: (@Sendable ([Float]) -> Void)?
    var failNext = false
    var onError: ((String) -> Void)?
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        if failNext { failNext = false; throw NSError(domain: "test", code: 1) }
        starts += 1
        running = onSamples
    }
    func stop() { stops += 1; running = nil }
}

/// Fires on any chunk whose first sample is 1.
private final class FakeSpotter: WakeWordSpotting, @unchecked Sendable {
    func accept(_ samples: [Float]) -> Bool { samples.first == 1 }
    func reset() {}
}

@MainActor
final class WakeWordListenerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var capture: FakeCapture!
    private var clock: TimeInterval = 100
    private var mic: WakeMicAccess = .granted

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(0.0, forKey: AppSettings.wakeWordResumeDelayKey)
        defaults.set(0.0, forKey: AppSettings.wakeWordCooldownKey)
        capture = FakeCapture()
    }

    private func make(installed: Bool = true, slowSpotter: Bool = false) -> WakeWordListener {
        let access = mic
        return WakeWordListener(defaults: defaults, capture: capture,
                                modelInstalled: { installed },
                                makeSpotter: {
                                    if slowSpotter { Thread.sleep(forTimeInterval: 0.05) }
                                    return FakeSpotter()
                                },
                                installModel: {},
                                authorizeMic: { access },
                                now: { [unowned self] in self.clock })
    }

    private func settleUnavailable(_ listener: WakeWordListener) async {
        for _ in 0..<200 { if case .unavailable = listener.state { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("expected unavailable, got \(listener.state)")
    }

    private func settle(_ listener: WakeWordListener, until state: WakeWordListener.State) async {
        for _ in 0..<200 where listener.state != state { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(listener.state, state)
    }

    func testOffByDefaultAndNeverOpensMic() {
        let listener = make()
        listener.start()
        XCTAssertFalse(listener.enabled)
        XCTAssertEqual(listener.state, .off)
        XCTAssertEqual(capture.starts, 0)
    }

    func testEnableWithoutModelAsksForInstall() {
        let listener = make(installed: false)
        listener.setEnabled(true)
        XCTAssertEqual(listener.state, .needsModel)
        XCTAssertEqual(capture.starts, 0)
    }

    func testEnableArmsAndPersists() async {
        let listener = make()
        listener.setEnabled(true)
        await settle(listener, until: .armed)
        XCTAssertEqual(capture.starts, 1)
        XCTAssertTrue(AppSettings.wakeWordEnabled(from: defaults))
        listener.setEnabled(false)
        XCTAssertEqual(listener.state, .off)
        XCTAssertEqual(capture.stops, 1)
    }

    func testDetectionReleasesMicAndFiresOnceUntilResumed() async {
        let listener = make()
        var wakes = 0
        listener.onWake = { wakes += 1 }
        listener.setEnabled(true)
        await settle(listener, until: .armed)
        capture.running?([1])
        await settle(listener, until: .paused)
        XCTAssertEqual(wakes, 1)
        XCTAssertTrue(listener.isPaused(.recognizer))
        XCTAssertEqual(capture.stops, 1)   // mic released before the recogniser opens it
        listener.setPaused(.recognizer, false)
        await settle(listener, until: .armed)
        XCTAssertEqual(capture.starts, 2)
    }

    func testPauseReasonsStack() async {
        let listener = make()
        listener.setEnabled(true)
        await settle(listener, until: .armed)
        listener.setPaused(.speaking, true)
        listener.setPaused(.hotkey, true)
        XCTAssertEqual(listener.state, .paused)
        listener.setPaused(.speaking, false)
        XCTAssertEqual(listener.state, .paused)   // hotkey still held
        listener.setPaused(.hotkey, false)
        await settle(listener, until: .armed)
    }

    func testCooldownIgnoresEarlyDetection() async {
        defaults.set(2.0, forKey: AppSettings.wakeWordCooldownKey)
        let listener = make()
        var wakes = 0
        listener.onWake = { wakes += 1 }
        listener.setEnabled(true)
        await settle(listener, until: .armed)
        listener.detected(generation: Int.max)   // stale generation: ignored
        capture.running?([1])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(wakes, 0)
        clock += 3
        capture.running?([1])
        await settle(listener, until: .paused)
        XCTAssertEqual(wakes, 1)
    }

    func testMicFailureIsReported() async {
        capture.failNext = true
        let listener = make()
        listener.setEnabled(true)
        await settleUnavailable(listener)
    }

    func testMicPermissionDeniedNeverOpensMic() async {
        mic = .denied("no mic")
        let listener = make()
        listener.setEnabled(true)
        await settleUnavailable(listener)
        XCTAssertEqual(listener.state, .unavailable("no mic"))
        XCTAssertEqual(capture.starts, 0)
    }

    func testReloadDuringLoadStillArms() async {
        let listener = make(slowSpotter: true)
        listener.setEnabled(true)
        listener.reload()
        listener.reload()
        await settle(listener, until: .armed)
        XCTAssertEqual(capture.starts, 1)
    }

    func testCaptureDyingIsReported() async {
        let listener = make()
        listener.setEnabled(true)
        await settle(listener, until: .armed)
        capture.onError?("device gone")
        XCTAssertEqual(listener.state, .unavailable("Wake word stopped: device gone"))
    }
}

final class WakeWordPhraseEncoderTests: XCTestCase {
    private let lexicon = ["HEY": ["HH", "EY1"], "HOME": ["HH", "OW1", "M"]]
    private let tokens: Set<String> = ["HH", "EY1", "OW1", "M"]

    func testEncodesPhraseCaseAndPunctuationInsensitive() throws {
        XCTAssertEqual(try WakeWordPhraseEncoder.encode("hey, Home!", lexicon: lexicon, tokens: tokens),
                       ["HH", "EY1", "HH", "OW1", "M"])
    }

    func testRejectsUnknownWordAndToken() {
        XCTAssertThrowsError(try WakeWordPhraseEncoder.encode("hey jarvis", lexicon: lexicon, tokens: tokens)) {
            XCTAssertEqual($0 as? WakeWordPhraseError, .unknownWord("JARVIS"))
        }
        XCTAssertThrowsError(try WakeWordPhraseEncoder.encode("hey", lexicon: lexicon, tokens: ["HH"])) {
            XCTAssertEqual($0 as? WakeWordPhraseError, .unknownToken("EY1"))
        }
        XCTAssertThrowsError(try WakeWordPhraseEncoder.encode("  ", lexicon: lexicon, tokens: tokens))
    }

    func testKeywordsLineFormat() {
        XCTAssertEqual(WakeWordPhraseEncoder.keywordsLine(phones: ["HH", "EY1"], boost: 1.5, threshold: 0.2, tag: "WAKE"),
                       "HH EY1 :1.5 #0.2 @WAKE")
    }
}

@MainActor
final class WakeWordWatchdogTests: XCTestCase {
    func testLostEndSignalIsReleasedByWatchdog() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(0.0, forKey: AppSettings.wakeWordResumeDelayKey)
        defaults.set(0.0, forKey: AppSettings.wakeWordCooldownKey)
        defaults.set(0.0, forKey: AppSettings.wakeWordMaxPauseKey)   // clamps to the 10 s floor
        let listener = WakeWordListener(defaults: defaults, capture: WatchdogCapture(), modelInstalled: { true },
                                        makeSpotter: { WatchdogSpotter() }, installModel: {}, authorizeMic: { .granted })
        XCTAssertEqual(AppSettings.wakeWordMaxPause(from: defaults), AppSettings.wakeWordMaxPauseRange.lowerBound)
        listener.setPaused(.hotkey, true)
        XCTAssertTrue(listener.isPaused(.hotkey))   // hotkey has no deadline
        listener.setPaused(.hotkey, false)
        listener.setPaused(.speaking, true)
        XCTAssertTrue(listener.isPaused(.speaking))
    }
}

private final class WatchdogCapture: WakeAudioCapturing {
    var onError: ((String) -> Void)?
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {}
    func stop() {}
}

private final class WatchdogSpotter: WakeWordSpotting {
    func accept(_ samples: [Float]) -> Bool { false }
    func reset() {}
}

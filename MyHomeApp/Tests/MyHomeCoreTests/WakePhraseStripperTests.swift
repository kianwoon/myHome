import XCTest
@testable import MyHomeCore

final class WakePhraseStripperTests: XCTestCase {
    func testBareWakePhraseInEngineSpellingsIsEmpty() {
        for text in ["Hey home.", "Hey, home.", "嘿，吼。", "Heyhu.", "嘿，home。", "hey home hey home"] {
            XCTAssertEqual(WakePhraseStripper.command(from: text), "", text)
        }
    }

    func testLeadingWakePhraseIsStripped() {
        XCTAssertEqual(WakePhraseStripper.command(from: "Hey home, turn off the study fan."), "turn off the study fan")
        XCTAssertEqual(WakePhraseStripper.command(from: "嘿，吼，关灯"), "关灯")
    }

    func testOrdinaryCommandUntouched() {
        XCTAssertEqual(WakePhraseStripper.command(from: "Turn on the home theatre"), "Turn on the home theatre")
        XCTAssertEqual(WakePhraseStripper.command(from: "Hey, how's the weather"), "Hey, how's the weather")
    }
}

final class WakePhraseStripperCustomTests: XCTestCase {
    func testCustomChinesePhraseIsStripped() {
        XCTAssertEqual(WakePhraseStripper.command(from: "小家小家，开灯。", spellings: ["小家小家"]), "开灯")
        XCTAssertEqual(WakePhraseStripper.command(from: "小家小家。", spellings: ["小家小家"]), "")
        XCTAssertEqual(WakePhraseStripper.command(from: "Hello house, lights off", spellings: ["Hello House"]), "lights off")
    }
}

@MainActor
final class WakePhraseSettingTests: XCTestCase {
    func testSetPhraseValidatesPersistsAndRejects() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        final class Cap: WakeAudioCapturing {
            var onError: ((String) -> Void)?
            func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {}
            func stop() {}
        }
        let listener = WakeWordListener(defaults: defaults, capture: Cap(), modelInstalled: { true },
                                        makeSpotter: { throw WakeWordPhraseError.unreadable }, installModel: {},
                                        authorizeMic: { .granted },
                                        validatePhrase: { $0.contains("jarvis") ? "unknown" : nil })
        XCTAssertNil(listener.setPhrase("  小家小家 "))
        XCTAssertEqual(listener.phrase, "小家小家")
        XCTAssertEqual(listener.setPhrase("hey jarvis"), "unknown")
        XCTAssertEqual(listener.phrase, "小家小家")   // rejected phrase changes nothing
        XCTAssertNotNil(listener.setPhrase("   "))
    }
}

final class VoiceDismissTests: XCTestCase {
    func testDismissWordsEndTheSession() {
        for text in ["Ignore.", "dismiss!", "Never mind", "算了。", "取消", "Cancel"] {
            XCTAssertTrue(VoiceDismiss.isDismissal(text), text)
        }
    }

    func testCommandsContainingTheWordsAreNotDismissals() {
        for text in ["Cancel the timer", "Ignore the hallway light and turn off the rest", "关灯", ""] {
            XCTAssertFalse(VoiceDismiss.isDismissal(text), text)
        }
    }

    func testWakeWaitIsTenSeconds() {
        XCTAssertEqual(AppSettings.wakeNoSpeechTimeout(from: UserDefaults(suiteName: UUID().uuidString)!), 10)
    }
}

import XCTest
@testable import MyHomeCore

private final class SpeechTestAnchor {}

@MainActor
final class SpeechGatingTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SpeechGatingTests-\(UUID())")!
    }

    func testTestBundleLacksUsageDescriptions() {
        XCTAssertFalse(SpeechCommandRecognizer.usageDescriptionsPresent(in: Bundle(for: SpeechTestAnchor.self)))
    }

    func testRequestAuthorizationDeniedWithoutUsageKeys() async {
        let recognizer = SpeechCommandRecognizer(defaults: isolatedDefaults(), bundle: Bundle(for: SpeechTestAnchor.self))
        let result = await recognizer.requestAuthorization()
        guard case .denied = result else { return XCTFail("expected denied, got \(result)") }
        XCTAssertFalse(recognizer.isSupported)
    }

    func testSpeakIsNoOpWhenRepliesDisabled() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: AppSettings.spokenRepliesKey)
        let responder = SpeechResponder(defaults: defaults)
        responder.speak("x")
        XCTAssertFalse(responder.isSpeaking)
    }
}

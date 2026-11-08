import XCTest
@testable import MyHomeCore

final class HotwordEchoTests: XCTestCase {
    private let hotwords = ["Air filter", "Dining fan", "Dining room", "Downlight", "Study fan", "Study light",
                            "Study room", "Curtain", "Water"]

    func testEchoedHotwordListIsRejected() {
        let echoed = "Air filter. Dining fan. Dining room. Downlight. Eight five seven. Study fan. Study light. "
            + "Study room. Study room. Curtain. Water."
        XCTAssertTrue(HotwordEcho.isEcho(echoed, hotwords: hotwords, audioSeconds: 20))
        XCTAssertTrue(HotwordEcho.isEcho(echoed, hotwords: hotwords, audioSeconds: 2.016))
    }

    func testNormalCommandWithSameHotwordsIsAccepted() {
        XCTAssertFalse(HotwordEcho.isEcho("dim the study room light to fifty percent", hotwords: hotwords,
                                          audioSeconds: 2.0))
    }

    func testShortNormalTranscriptIsAccepted() {
        XCTAssertFalse(HotwordEcho.isEcho("Water", hotwords: hotwords, audioSeconds: 0.8))
        XCTAssertFalse(HotwordEcho.isEcho("", hotwords: hotwords, audioSeconds: 1))
    }

    func testImplausibleSpeechRateIsRejectedWithoutHotwords() {
        let text = String(repeating: "a", count: 392)
        XCTAssertTrue(HotwordEcho.isEcho(text, hotwords: [], audioSeconds: 2.016))
        XCTAssertFalse(HotwordEcho.isEcho(text, hotwords: [], audioSeconds: 60))
    }

    func testHotwordBiasDefaultsOffAndListIsBounded() {
        XCTAssertFalse(AppSettings.defaultSpeechHotwordBias)
        let suite = UserDefaults(suiteName: "HotwordEchoTests-\(UUID().uuidString)")!
        XCTAssertFalse(AppSettings.speechHotwordBias(from: suite))
        XCTAssertLessThanOrEqual(AppSettings.speechMaxHotwords, 20)
    }
}

final class QwenLanguageTests: XCTestCase {
    func testLocaleMapsToQwenLanguageName() {
        XCTAssertEqual(QwenLanguage.name(for: "en-GB"), "English")
        XCTAssertEqual(QwenLanguage.name(for: "zh-Hans"), "Chinese")
    }
}

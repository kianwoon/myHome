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

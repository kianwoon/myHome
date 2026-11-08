import Foundation
import XCTest
@testable import MyHomeCore

final class VoiceCommandParserTests: XCTestCase {
    private let parser = VoiceCommandParser()

    private func command(_ text: String) -> (DeviceQuery, DeviceCommand)? {
        if case .command(let query, let command) = parser.parse(text) { return (query, command) }
        XCTFail("not a command: \(text) → \(parser.parse(text))")
        return nil
    }

    func testSpelledAndMisheardNumbers() {
        let parser = VoiceCommandParser()
        for phrase in ["set the study fan speed to 2", "set the study fan speed to two", "change the study fan speed to do",
                       "set the study fan speed to too"] {
            guard case .command(let query, .fanSpeed(2)) = parser.parse(phrase) else { return XCTFail(phrase) }
            XCTAssertEqual(query.text, "study fan", phrase)
        }
        // A sound-alike is only trusted as a speed value, never as a mode or name.
        if case .command(_, .fanSpeed) = parser.parse("set the study fan to do") { XCTFail("homophone leaked outside speed") }
    }

    func testPowerPhrasings() {
        XCTAssertEqual(command("turn off the bedroom lights")?.1, .power(false))
        XCTAssertEqual(command("turn off the bedroom lights")?.0.text, "bedroom lights")
        XCTAssertEqual(command("Please switch the kitchen plug off.")?.0.text, "kitchen plug")
        XCTAssertEqual(command("Please switch the kitchen plug off.")?.1, .power(false))
        XCTAssertEqual(command("study fan on")?.1, .power(true))
        XCTAssertEqual(command("power on the desk lamp")?.0.text, "desk lamp")
        XCTAssertEqual(command("turn everything off")?.0.text, "everything")
    }

    func testRoomPreposition() {
        let parsed = command("turn off the lights in the master bedroom")
        XCTAssertEqual(parsed?.0.text, "lights")
        XCTAssertEqual(parsed?.0.room, "master bedroom")
        XCTAssertEqual(parsed?.1, .power(false))
    }

    func testLevelsPercentAndGears() {
        XCTAssertEqual(command("set study fan to 50%")?.1, .level(50))
        XCTAssertEqual(command("set study fan to 50%")?.0.text, "study fan")
        XCTAssertEqual(command("set the study fan to 50 percent")?.1, .level(50))
        XCTAssertEqual(command("set study fan speed to 3")?.1, .fanSpeed(3))
        XCTAssertEqual(command("set study fan speed to 3")?.0.text, "study fan")
        XCTAssertEqual(command("study fan speed 4")?.1, .fanSpeed(4))
        XCTAssertEqual(command("study fan speed 4")?.0.text, "study fan")
        XCTAssertEqual(command("set the fan to 3")?.1, .fanSpeed(3), "bare small number is a gear")
        XCTAssertEqual(command("set the lamp to 60")?.1, .level(60), "bare large number is a percent")
        XCTAssertEqual(command("dim the bedroom lights to 5")?.1, .level(5), "dim implies brightness")
        XCTAssertEqual(command("set desk lamp brightness to 80")?.1, .level(80))
        XCTAssertEqual(command("set desk lamp brightness to 80")?.0.text, "desk lamp")
        XCTAssertEqual(command("move the curtain to 40%")?.1, .level(40))
    }

    func testModesColoursAndTemperature() {
        XCTAssertEqual(command("set the study fan to sleep mode")?.1, .mode("sleep"))
        XCTAssertEqual(command("set study fan mode to nature")?.1, .mode("nature"))
        XCTAssertEqual(command("set study fan mode to nature")?.0.text, "study fan")
        XCTAssertEqual(command("set the reading lamp to red")?.1, .color(RGB(red: 255, green: 0, blue: 0)))
        XCTAssertEqual(command("make the reading lamp blue")?.1, .color(RGB(red: 0, green: 0, blue: 255)))
        XCTAssertEqual(command("make the reading lamp blue")?.0.text, "reading lamp")
        XCTAssertEqual(command("set the reading lamp to warm white")?.1, .colorTemperature(0))
        XCTAssertEqual(command("make the lamp cool white")?.1, .colorTemperature(100))
        XCTAssertEqual(command("make the lamp cool white")?.0.text, "lamp")
    }

    func testCovers() {
        XCTAssertEqual(command("open the study curtain")?.1, .cover(.open))
        XCTAssertEqual(command("open the study curtain")?.0.text, "study curtain")
        XCTAssertEqual(command("close the blinds")?.1, .cover(.close))
        XCTAssertEqual(command("stop the curtain")?.1, .cover(.stop))
    }

    func testStatusConfirmCancelUnknown() {
        XCTAssertEqual(parser.parse("is the study fan on"), .status(DeviceQuery(text: "study fan")))
        XCTAssertEqual(parser.parse("yes"), .confirm)
        XCTAssertEqual(parser.parse("go ahead"), .confirm)
        XCTAssertEqual(parser.parse("no, cancel"), .cancel)
        XCTAssertEqual(parser.parse("never mind"), .cancel)
        XCTAssertEqual(parser.parse("what is the meaning of life"), .status(DeviceQuery(text: "meaning life")))
        // Playback is now a speaker command ("play some music" = last/first station).
        XCTAssertEqual(parser.parse("play some music"), .command(DeviceQuery(text: ""), .play("some music")))
        XCTAssertEqual(parser.parse("   "), .unknown("   "))
    }
}

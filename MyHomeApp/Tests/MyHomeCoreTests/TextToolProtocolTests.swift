import Foundation
import XCTest
@testable import MyHomeCore

final class TextToolProtocolTests: XCTestCase {
    func testParsesOneObjectPerLineAndKeepsTheProse() {
        let text = """
        Let me check.
        {"tool":"get_state","arguments":{"handles":["fan-to2l"]}}
        {"tool": "count", "arguments": {"kind": "light", "state": "on"}}
        """
        let parsed = TextToolProtocol.parse(text)
        XCTAssertEqual(parsed.calls.map(\.name), ["get_state", "count"])
        XCTAssertEqual(parsed.calls[0].arguments["handles"], .array([.string("fan-to2l")]))
        XCTAssertEqual(parsed.calls[1].arguments["kind"], .string("light"))
        XCTAssertEqual(parsed.calls[0].id, "text-call-1")
        XCTAssertEqual(parsed.remainder, "Let me check.")
    }

    func testFencesAlternateKeysAndStringArgumentsAreAccepted() {
        let text = """
        ```json
        {"name":"set","args":"{\\"handles\\":[\\"light-8e6d\\"],\\"action\\":\\"level\\",\\"value\\":50}"}
        ```
        """
        let parsed = TextToolProtocol.parse(text)
        XCTAssertEqual(parsed.calls.count, 1)
        XCTAssertEqual(parsed.calls[0].name, "set")
        XCTAssertEqual(parsed.calls[0].arguments["value"], .number(50))
        XCTAssertEqual(parsed.remainder, "")
    }

    func testPrettyPrintedSingleObjectIsOneCall() {
        let text = """
        {
          "tool": "now",
          "arguments": {}
        }
        """
        let parsed = TextToolProtocol.parse(text)
        XCTAssertEqual(parsed.calls.map(\.name), ["now"])
    }

    func testPlainProseHasNoCalls() {
        let parsed = TextToolProtocol.parse("Very good. The study lights are at half. {not json}")
        XCTAssertTrue(parsed.calls.isEmpty)
        XCTAssertTrue(parsed.remainder.hasPrefix("Very good."))
    }

    func testRenderListsEveryToolAndTheContract() {
        let text = TextToolProtocol.render(HousekeeperTools.definitions)
        for tool in HousekeeperTools.definitions { XCTAssertTrue(text.contains("- \(tool.name): "), tool.name) }
        XCTAssertTrue(text.contains(TextToolProtocol.resultLead))
        XCTAssertTrue(text.contains("{\"tool\":\"<name>\",\"arguments\":{…}}"))
        let line = TextToolProtocol.line(for: AgentToolCall(id: "x", name: "set", arguments: ["action": .string("level"), "value": .number(50)]))
        XCTAssertEqual(line, "{\"arguments\":{\"action\":\"level\",\"value\":50},\"tool\":\"set\"}")
    }

    func testJSONValueBridgesBooleansNumbersAndText() {
        let value = JSONValue.parse("{\"on\":true,\"n\":2,\"s\":\"x\",\"list\":[1,\"a\",null]}")
        XCTAssertEqual(value?.objectValue?["on"], .bool(true))
        XCTAssertEqual(value?.objectValue?["n"], .number(2))
        XCTAssertEqual(value?.objectValue?["list"], .array([.number(1), .string("a"), .null]))
        XCTAssertEqual(value?.jsonText, "{\"list\":[1,\"a\",null],\"n\":2,\"on\":true,\"s\":\"x\"}")
        XCTAssertEqual(JSONValue.string("42").doubleValue, 42)
        XCTAssertEqual(HousekeeperTools.integer(.string(" 50% ")), 50)
        XCTAssertEqual(HousekeeperTools.integer(.number(49.6)), 50)
        XCTAssertNil(HousekeeperTools.integer(.string("half")))
    }
}

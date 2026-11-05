// Pins JevClient's decisions request to opencode's wire format. The golden body
// was captured from opencode's real `jevAsk` (packages/core/src/jev/client.ts,
// run under bun against a local capture server, fake key) for the same state
// and questions. Any drift (escaped slashes, key order, header casing) fails here.
import XCTest
@testable import MyHomeCore

final class JevWireGoldenTests: XCTestCase {
    // allow-hardcode: captured opencode golden (fake key, fake ids).
    private let fakeKey = "sk-or-v1-XXXXXXXX"
    private let state = "Utterance: \"turn on the café light\"\nRoom: living/dining \\ tab\there <tag> & 50%"
    private let openCodeBody = #"{"model":"perplexity/pplx-decider-flash-v1.2","state":"Utterance: \"turn on the café light\"\nRoom: living/dining \\ tab\there <tag> & 50%","questions":{"device":{"type":"choice","instructions":"Which device did the user mean?","criteria":{"d1":"Café lamp (living/dining)","d2":"Desk lamp"}},"ping":{"type":"choice","instructions":"Is this message a connectivity check?","criteria":{"no":"The message is something else.","yes":"The message is a connectivity check."}}}}"#

    private var questions: [String: JevQuestion] {
        ["device": JevQuestion(instructions: "Which device did the user mean?", criteria: ["d1": "Café lamp (living/dining)", "d2": "Desk lamp"]),
         JevClient.pingID: JevQuestion(instructions: JevClient.pingInstructions, criteria: JevClient.pingCriteria)]
    }

    private func request(model: String) throws -> URLRequest {
        let client = JevClient(config: .init(model: model), key: fakeKey, transport: ClosureJevTransport { _ in throw URLError(.cancelled) })
        return try client.buildRequest(state: state, questions: questions)
    }

    func testBodyIsByteIdenticalToOpencode() throws {
        let body = try XCTUnwrap(request(model: "openrouter/perplexity/pplx-decider-flash-v1.2").httpBody)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), openCodeBody)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(#"\/"#), "slashes in the model id must not be escaped")
    }

    func testBareAndPrefixedModelSpecsSendTheSameWireId() throws {
        let bare = try request(model: " perplexity/pplx-decider-flash-v1.2\n").httpBody
        let prefixed = try request(model: "openrouter/perplexity/pplx-decider-flash-v1.2").httpBody
        XCTAssertEqual(bare, prefixed)
    }

    func testHeadersMatchOpencodeNamesAndAuthFormat() throws {
        let sent = try request(model: "perplexity/pplx-decider-flash-v1.2")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://openrouter.ai/api/alpha/decisions")
        let headers = try XCTUnwrap(sent.allHTTPHeaderFields)
        XCTAssertEqual(Set(headers.keys), ["Authorization", "Content-Type", "HTTP-Referer", "X-Title"])
        XCTAssertEqual(headers["Authorization"], "Bearer \(fakeKey)")
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["HTTP-Referer"], AppSettings.jevReferer)
        XCTAssertEqual(headers["X-Title"], AppSettings.jevAppTitle)
    }
}

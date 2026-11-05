import Foundation
import XCTest
@testable import MyHomeCore

private final class AgentMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, [String: Any]) throws -> (Int, Data))?
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.bodies.append(json)
        do {
            let (status, data) = try Self.handler?(request, json) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

private func openAIReply(content: Any?, toolCalls: [[String: Any]]? = nil, reasoning: String? = nil, finish: String = "stop") -> Data {
    var message: [String: Any] = ["role": "assistant", "content": content ?? NSNull()]
    if let toolCalls { message["tool_calls"] = toolCalls }
    if let reasoning { message["reasoning_content"] = reasoning }
    return json(["choices": [["message": message, "finish_reason": finish]], "usage": ["prompt_tokens": 120, "completion_tokens": 30]])
}

private func openAICall(id: String, name: String, arguments: String) -> [String: Any] {
    ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
}

@MainActor
final class AgentTransportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var secrets: InMemorySecretStore!
    private var session: URLSession!
    private let secretKey = "sk-test-SECRET-0123456789"
    private let tool = AgentToolDefinition(name: "ping", description: "test", parameters: .object(["type": .string("object"), "properties": .object([:])]))

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AgentTransportTests-\(UUID())")!
        secrets = InMemorySecretStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentMockURLProtocol.self]
        session = URLSession(configuration: config)
        AgentMockURLProtocol.bodies = []
        AgentMockURLProtocol.handler = nil
    }

    private func configure(_ provider: AppSettings.PlannerProvider, model: String = "test-model") {
        defaults.set(provider.rawValue, forKey: AppSettings.plannerProviderKey)
        defaults.set(model, forKey: provider == .anthropic ? AppSettings.anthropicModelKey : AppSettings.openAIModelKey)
        try? secrets.write(secretKey, account: AppSettings.plannerSecretAccount(for: provider))
    }

    private func openAI(preferred: AppSettings.ToolCallMode? = nil) -> OpenAIAgentTransport {
        configure(.openAICompatible)
        return OpenAIAgentTransport(defaults: defaults, secrets: secrets, session: session, requestTimeout: 5, preferred: preferred)
    }

    private func messages(_ body: [String: Any]) -> [[String: Any]] { body["messages"] as? [[String: Any]] ?? [] }

    // MARK: OpenAI-compatible

    func testNativeToolCallsAreParsedAndSentBackWithTheirResults() async throws {
        let transport = openAI()
        AgentMockURLProtocol.handler = { _, _ in
            (200, openAIReply(content: "", toolCalls: [openAICall(id: "call_1", name: "ping", arguments: "{\"x\": 1}")], reasoning: "thinking hard", finish: "tool_calls"))
        }
        let turn = try await transport.complete([.system("sys"), .user("go")], tools: [tool])
        XCTAssertEqual(turn.toolCalls, [AgentToolCall(id: "call_1", name: "ping", arguments: ["x": .number(1)])])
        XCTAssertEqual(turn.wire, .native)
        XCTAssertEqual(turn.reasoning, "thinking hard")
        XCTAssertEqual(turn.usage?.promptTokens, 120)
        let first = AgentMockURLProtocol.bodies[0]
        XCTAssertNotNil(first["tools"], "native mode sends the tool definitions")
        XCTAssertEqual((first["tools"] as? [[String: Any]])?.first?["type"] as? String, "function")
        XCTAssertEqual(first["tool_choice"] as? String, "auto")
        XCTAssertEqual(first["model"] as? String, "test-model")
        // Second round: the assistant turn (with reasoning echoed) and a role-tool result.
        AgentMockURLProtocol.handler = { _, _ in (200, openAIReply(content: "<think>hmm</think>OK")) }
        let history: [AgentMessage] = [.system("sys"), .user("go"), .assistant(text: "", toolCalls: turn.toolCalls, reasoning: turn.reasoning),
                                       .tool(callID: "call_1", name: "ping", content: "pong")]
        let final = try await transport.complete(history, tools: [tool])
        XCTAssertEqual(final.text, "OK", "hidden reasoning is stripped")
        XCTAssertTrue(final.toolCalls.isEmpty)
        let sent = messages(AgentMockURLProtocol.bodies[1])
        XCTAssertEqual(sent.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(sent[2]["reasoning_content"] as? String, "thinking hard")
        XCTAssertEqual(((sent[2]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["arguments"] as? String, "{\"x\":1}")
        XCTAssertEqual(sent[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(sent[3]["content"] as? String, "pong")
    }

    func testEmptyReplyWithLengthFinishReportsOutOfTokens() async {
        let transport = openAI()
        AgentMockURLProtocol.handler = { _, _ in (200, openAIReply(content: "", reasoning: "……", finish: "length")) }
        do {
            _ = try await transport.complete([.user("go")], tools: [tool])
            XCTFail("expected an error")
        } catch let error as AgentTransportError {
            XCTAssertEqual(error, .failed(CloudPlanner.outOfTokensMessage))
        } catch { XCTFail("\(error)") }
    }

    func testProviderRejectingToolsFallsBackToTheTextProtocol() async throws {
        let transport = openAI()
        AgentMockURLProtocol.handler = { _, body in
            if body["tools"] != nil { return (400, Data("tools are not supported".utf8)) }
            return (200, openAIReply(content: "{\"tool\":\"ping\",\"arguments\":{}}"))
        }
        let turn = try await transport.complete([.system("sys"), .user("go")], tools: [tool])
        XCTAssertEqual(turn.toolCalls.map(\.name), ["ping"])
        XCTAssertEqual(turn.wire, .text)
        XCTAssertEqual(transport.toolWire, .text, "stays on text from now on")
        XCTAssertEqual(AgentMockURLProtocol.bodies.count, 2)
        let retry = AgentMockURLProtocol.bodies[1]
        XCTAssertNil(retry["tools"])
        let system = messages(retry)[0]["content"] as? String ?? ""
        XCTAssertTrue(system.hasPrefix("sys\n\nTOOLS."), system)
        XCTAssertTrue(system.contains("- ping: test"))
        // Results for text calls travel as a user message, never as role tool.
        AgentMockURLProtocol.handler = { _, _ in (200, openAIReply(content: "done")) }
        _ = try await transport.complete([.system("sys"), .user("go"), .assistant(text: "", toolCalls: turn.toolCalls, reasoning: nil),
                                          .tool(callID: turn.toolCalls[0].id, name: "ping", content: "pong")], tools: [tool])
        let sent = messages(AgentMockURLProtocol.bodies[2])
        XCTAssertEqual(sent.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(sent[2]["content"] as? String, "{\"arguments\":{},\"tool\":\"ping\"}")
        XCTAssertTrue((sent[3]["content"] as? String ?? "").hasPrefix("TOOL RESULT ping (text-call-1):\npong"))
    }

    func testToolLinesInsideANativeReplyAreStillCalls() async throws {
        let transport = openAI()
        AgentMockURLProtocol.handler = { _, _ in (200, openAIReply(content: "Checking.\n{\"tool\":\"ping\",\"arguments\":{\"a\":\"b\"}}")) }
        let turn = try await transport.complete([.user("go")], tools: [tool])
        XCTAssertEqual(turn.toolCalls.map(\.name), ["ping"])
        XCTAssertEqual(turn.toolCalls[0].arguments["a"], .string("b"))
        XCTAssertEqual(turn.text, "Checking.")
        XCTAssertEqual(turn.wire, .text)
        XCTAssertEqual(transport.toolWire, .native, "a stray text call does not abandon native mode")
    }

    func testAuthErrorsAndMissingKeysNeverQuoteTheKey() async {
        let transport = openAI()
        AgentMockURLProtocol.handler = { _, _ in (401, Data("bad key \(self.secretKey)".utf8)) }
        do {
            _ = try await transport.complete([.user("go")], tools: [tool])
            XCTFail("expected an error")
        } catch let error as AgentTransportError {
            XCTAssertFalse(error.message.contains(secretKey))
            XCTAssertTrue(error.message.contains("rejected the API key"), error.message)
        } catch { XCTFail("\(error)") }
        try? secrets.delete(account: AppSettings.plannerSecretAccount(for: .openAICompatible))
        XCTAssertEqual(transport.unavailableReason, "add an API key in Settings → Assistant")
    }

    func testPreferredAndProbedModesPickTheWire() {
        XCTAssertEqual(openAI(preferred: .text).toolWire, .text)
        XCTAssertEqual(openAI(preferred: .native).toolWire, .native)
        XCTAssertEqual(openAI().toolWire, .native)
        AppSettings.recordHousekeeperProbe(mode: "text", model: "test-model", in: defaults)
        XCTAssertEqual(openAI().toolWire, .text, "auto follows the recorded probe")
        XCTAssertEqual(AppSettings.housekeeperProbeSummary(from: defaults)?.hasPrefix("Tool calls: text (test-model, probed "), true)
    }

    // MARK: Anthropic

    func testAnthropicUsesToolUseBlocksAndToolResults() async throws {
        configure(.anthropic)
        let transport = AnthropicAgentTransport(defaults: defaults, secrets: secrets, session: session, requestTimeout: 5)
        AgentMockURLProtocol.handler = { _, _ in
            (200, json(["content": [["type": "thinking", "thinking": "…"], ["type": "text", "text": "Let me check."],
                                    ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": ["x": 1]]],
                        "stop_reason": "tool_use", "usage": ["input_tokens": 10, "output_tokens": 5]]))
        }
        let turn = try await transport.complete([.system("sys"), .user("go")], tools: [tool])
        XCTAssertEqual(turn.toolCalls, [AgentToolCall(id: "toolu_1", name: "ping", arguments: ["x": .number(1)])])
        XCTAssertEqual(turn.text, "Let me check.")
        XCTAssertEqual(turn.finishReason, "tool_use")
        let first = AgentMockURLProtocol.bodies[0]
        XCTAssertEqual(first["system"] as? String, "sys")
        XCTAssertEqual((first["tools"] as? [[String: Any]])?.first?["input_schema"] != nil, true)
        AgentMockURLProtocol.handler = { _, _ in (200, json(["content": [["type": "text", "text": "OK"]], "stop_reason": "end_turn"])) }
        _ = try await transport.complete([.system("sys"), .user("go"), .assistant(text: turn.text, toolCalls: turn.toolCalls, reasoning: nil),
                                          .tool(callID: "toolu_1", name: "ping", content: "pong")], tools: [tool])
        let sent = messages(AgentMockURLProtocol.bodies[1])
        XCTAssertEqual(sent.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistantBlocks = sent[1]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(assistantBlocks.map { $0["type"] as? String }, ["text", "tool_use"])
        let resultBlocks = sent[2]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(resultBlocks.first?["type"] as? String, "tool_result")
        XCTAssertEqual(resultBlocks.first?["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(AgentMockURLProtocol.bodies[1]["max_tokens"] as? Int, AppSettings.defaultPlannerMaxTokens)
    }

    // MARK: Probe

    func testProbeReportsNativeThenTextThenNone() async {
        configure(.openAICompatible)
        AgentMockURLProtocol.handler = { _, _ in (200, openAIReply(content: "", toolCalls: [openAICall(id: "c", name: "ping", arguments: "{}")], finish: "tool_calls")) }
        let native = await AgentToolProbe.runAndRecord(defaults: defaults, secrets: secrets, session: session)
        XCTAssertEqual(native, .native)
        XCTAssertEqual(defaults.string(forKey: AppSettings.housekeeperProbedModeKey), "native")
        XCTAssertEqual(AgentMockURLProtocol.bodies.last?["max_completion_tokens"] as? Int, AppSettings.housekeeperProbeMaxTokens)
        AgentMockURLProtocol.handler = { _, body in
            body["tools"] != nil ? (200, openAIReply(content: "I cannot call tools.")) : (200, openAIReply(content: "{\"tool\":\"ping\",\"arguments\":{}}"))
        }
        let text = await AgentToolProbe.runAndRecord(defaults: defaults, secrets: secrets, session: session)
        XCTAssertEqual(text, .text)
        XCTAssertEqual(defaults.string(forKey: AppSettings.housekeeperProbedModeKey), "text")
        AgentMockURLProtocol.handler = { _, _ in (200, openAIReply(content: "No tools here.")) }
        let none = await AgentToolProbe.runAndRecord(defaults: defaults, secrets: secrets, session: session)
        XCTAssertEqual(none, .noToolCall("No tools here."))
        XCTAssertEqual(defaults.string(forKey: AppSettings.housekeeperProbedModeKey), "text", "an inconclusive probe keeps the last good record")
    }
}

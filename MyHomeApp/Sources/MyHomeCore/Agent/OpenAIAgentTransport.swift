// AgentTransport on an OpenAI-compatible chat-completions server (OpenAI,
// OpenRouter, DeepSeek, local servers, proxies). Native function calling
// (`tools` / `tool_calls` / role "tool") when the provider passes it through;
// otherwise the text protocol. Reasoning models are handled: `<think>` blocks
// are stripped, `reasoning_content` is captured and echoed back on the same
// turn (DeepSeek thinking mode requires it), and an empty reply with
// finish_reason "length" is reported as running out of tokens.
import Foundation

@MainActor
public final class OpenAIAgentTransport: AgentTransport {
    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let session: URLSession
    /// Bound on one request; the agent sets it from its limits.
    public var requestTimeout: TimeInterval
    /// Overrides the user's max-token setting (the probe keeps it small).
    public var maxTokensOverride: Int?
    /// Set when the provider rejected a request carrying `tools`: text from then on.
    private(set) var fellBackToText = false
    private let preferred: AppSettings.ToolCallMode?

    public init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore(),
                session: URLSession = CloudPlanner.makeSession(),
                requestTimeout: TimeInterval = AppSettings.defaultHousekeeperRequestTimeout,
                preferred: AppSettings.ToolCallMode? = nil) {
        self.defaults = defaults
        self.secrets = secrets
        self.session = session
        self.requestTimeout = requestTimeout
        self.preferred = preferred
    }

    public var unavailableReason: String? { AgentHTTP.Context.resolve(defaults: defaults, secrets: secrets).problem }

    public var toolWire: AgentToolWire {
        if fellBackToText { return .text }
        switch preferred ?? AppSettings.housekeeperToolMode(from: defaults) {
        case .text: return .text
        case .native: return .native
        case .auto:
            return defaults.string(forKey: AppSettings.housekeeperProbedModeKey) == AgentToolWire.text.rawValue ? .text : .native
        }
    }

    public func complete(_ messages: [AgentMessage], tools: [AgentToolDefinition]) async throws -> AgentTurn {
        let context = AgentHTTP.Context.resolve(defaults: defaults, secrets: secrets)
        if let problem = context.problem {
            AppLog.assistant.info("housekeeper transport unavailable: \(context.secret.logSummary, privacy: .public)")
            throw AgentTransportError.unavailable(problem)
        }
        let wire = toolWire
        do {
            return try await send(messages, tools: tools, wire: wire, context: context)
        } catch let status as AgentHTTP.Status {
            guard wire == .native, !tools.isEmpty, status.mayBeToolRejection else { throw AgentTransportError.failed(status.message) }
            // The provider refused the request with tools: say so once, then use the text protocol.
            AppLog.assistant.notice("housekeeper: provider answered HTTP \(status.code, privacy: .public) to native tool calls; switching to the text protocol")
            fellBackToText = true
            do {
                return try await send(messages, tools: tools, wire: .text, context: context)
            } catch let again as AgentHTTP.Status {
                throw AgentTransportError.failed(again.message)
            }
        }
    }

    // MARK: - Request

    private func send(_ messages: [AgentMessage], tools: [AgentToolDefinition], wire: AgentToolWire, context: AgentHTTP.Context) async throws -> AgentTurn {
        let body = Self.body(messages: messages, tools: tools, wire: wire, model: context.config.model,
                             maxTokens: maxTokensOverride ?? context.config.maxTokens)
        let request = try AgentHTTP.request(context: context, body: body, timeout: requestTimeout)
        let root = try await AgentHTTP.send(request, session: session, key: context.key)
        return try Self.turn(from: root, wire: wire)
    }

    static func body(messages: [AgentMessage], tools: [AgentToolDefinition], wire: AgentToolWire, model: String, maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = ["model": model, "max_completion_tokens": maxTokens,
                                   "messages": wireMessages(messages, tools: tools, wire: wire)]
        if wire == .native, !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": tool.parameters.any]]
            }
            body["tool_choice"] = "auto"
        }
        return body
    }

    /// Provider-neutral messages → chat-completions messages. Tool calls that
    /// travelled as text (ids with the text prefix) stay text in history, so a
    /// native provider is never shown a tool_call_id it did not issue.
    static func wireMessages(_ messages: [AgentMessage], tools: [AgentToolDefinition], wire: AgentToolWire) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pendingResults: [String] = []
        func flushResults() {
            guard !pendingResults.isEmpty else { return }
            out.append(["role": "user", "content": pendingResults.joined(separator: "\n\n")])
            pendingResults = []
        }
        for message in messages {
            switch message {
            case .system(let text):
                flushResults()
                let content = wire == .text && !tools.isEmpty ? text + "\n\n" + TextToolProtocol.render(tools) : text
                out.append(["role": "system", "content": content])
            case .user(let text):
                flushResults()
                out.append(["role": "user", "content": text])
            case .assistant(let text, let calls, let reasoning):
                flushResults()
                let native = wire == .native ? calls.filter { !$0.id.hasPrefix(TextToolProtocol.callIDPrefix) } : []
                let textual = calls.filter { !native.contains($0) }
                var content = text
                if !textual.isEmpty {
                    content = ([text] + textual.map(TextToolProtocol.line(for:))).filter { !$0.isEmpty }.joined(separator: "\n")
                }
                var entry: [String: Any] = ["role": "assistant", "content": content]
                if !native.isEmpty {
                    entry["tool_calls"] = native.map { call -> [String: Any] in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": JSONValue.object(call.arguments).jsonText]]
                    }
                }
                if let reasoning, !reasoning.isEmpty, wire == .native { entry["reasoning_content"] = reasoning }
                out.append(entry)
            case .tool(let callID, let name, let content):
                if wire == .native, !callID.hasPrefix(TextToolProtocol.callIDPrefix) {
                    flushResults()
                    out.append(["role": "tool", "tool_call_id": callID, "content": content])
                } else {
                    pendingResults.append(TextToolProtocol.resultText(name: name, callID: callID, content: content))
                }
            }
        }
        flushResults()
        return out
    }

    // MARK: - Reply

    static func turn(from root: [String: Any], wire: AgentToolWire) throws -> AgentTurn {
        let choice = (root["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        let finish = choice?["finish_reason"] as? String
        let raw = CloudPlanner.contentText(message?["content"]).nonEmptyText ?? CloudPlanner.contentText(choice?["text"])
        var text = CloudPlanner.stripThinking(raw)
        let reasoning = (message?["reasoning_content"] as? String) ?? (message?["reasoning"] as? String)
        var calls = nativeCalls(message?["tool_calls"])
        var usedWire = wire
        if calls.isEmpty, !text.isEmpty {
            // Tool-call lines in the text: the text protocol, whichever mode was asked for.
            let parsed = TextToolProtocol.parse(text)
            if !parsed.calls.isEmpty {
                calls = parsed.calls
                text = parsed.remainder
                usedWire = .text
            }
        } else if !calls.isEmpty {
            usedWire = .native
        }
        if calls.isEmpty, text.isEmpty {
            let completion = AgentHTTP.usage(from: root)?.completionTokens
            AppLog.assistant.info("housekeeper reply had no text: keys=\(root.keys.sorted().joined(separator: ","), privacy: .public) finish=\(finish ?? "none", privacy: .public) completion_tokens=\(completion.map(String.init) ?? "none", privacy: .public)")
            if let finish, CloudPlanner.truncationReasons.contains(finish) { throw AgentTransportError.failed(CloudPlanner.outOfTokensMessage) }
            throw AgentTransportError.failed(CloudPlanner.emptyReplyMessage)
        }
        return AgentTurn(text: text, toolCalls: calls, reasoning: reasoning, finishReason: finish, usage: AgentHTTP.usage(from: root), wire: usedWire)
    }

    static func nativeCalls(_ value: Any?) -> [AgentToolCall] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.enumerated().compactMap { index, item in
            let function = item["function"] as? [String: Any] ?? item
            guard let name = function["name"] as? String, !name.isEmpty else { return nil }
            let id = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call-\(index + 1)"
            var arguments: [String: JSONValue] = [:]
            if let text = function["arguments"] as? String {
                arguments = JSONValue.parse(text)?.objectValue ?? [:]
            } else if let object = function["arguments"] as? [String: Any] {
                arguments = JSONValue(any: object).objectValue ?? [:]
            }
            return AgentToolCall(id: id, name: name, arguments: arguments)
        }
    }
}

extension String {
    var nonEmptyText: String? { isEmpty ? nil : self }
}

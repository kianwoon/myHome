// AgentTransport on the Anthropic Messages API: native `tools` / `tool_use`
// / `tool_result` content blocks, or the text protocol when asked for.
// Thinking blocks are ignored (only text blocks are read); stop_reason
// "max_tokens" with no visible text is reported as running out of tokens.
import Foundation

@MainActor
public final class AnthropicAgentTransport: AgentTransport {
    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let session: URLSession
    public var requestTimeout: TimeInterval
    public var maxTokensOverride: Int?
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
            AppLog.assistant.notice("housekeeper: provider answered HTTP \(status.code, privacy: .public) to native tool calls; switching to the text protocol")
            fellBackToText = true
            do {
                return try await send(messages, tools: tools, wire: .text, context: context)
            } catch let again as AgentHTTP.Status {
                throw AgentTransportError.failed(again.message)
            }
        }
    }

    private func send(_ messages: [AgentMessage], tools: [AgentToolDefinition], wire: AgentToolWire, context: AgentHTTP.Context) async throws -> AgentTurn {
        let body = Self.body(messages: messages, tools: tools, wire: wire, model: context.config.model,
                             maxTokens: maxTokensOverride ?? context.config.maxTokens)
        let request = try AgentHTTP.request(context: context, body: body, timeout: requestTimeout)
        let root = try await AgentHTTP.send(request, session: session, key: context.key)
        return try Self.turn(from: root, wire: wire)
    }

    // MARK: - Request

    static func body(messages: [AgentMessage], tools: [AgentToolDefinition], wire: AgentToolWire, model: String, maxTokens: Int) -> [String: Any] {
        var system: [String] = []
        var turns: [[String: Any]] = []
        /// Blocks waiting to be flushed as one message of `role`.
        var role = ""
        var blocks: [[String: Any]] = []
        func flush() {
            guard !blocks.isEmpty else { return }
            turns.append(["role": role, "content": blocks])
            blocks = []
        }
        func append(_ newRole: String, _ block: [String: Any]) {
            if newRole != role { flush(); role = newRole }
            blocks.append(block)
        }
        for message in messages {
            switch message {
            case .system(let text):
                system.append(text)
            case .user(let text):
                append("user", ["type": "text", "text": text])
            case .assistant(let text, let calls, _):
                let native = wire == .native ? calls.filter { !$0.id.hasPrefix(TextToolProtocol.callIDPrefix) } : []
                let textual = calls.filter { !native.contains($0) }
                var content = text
                if !textual.isEmpty {
                    content = ([text] + textual.map(TextToolProtocol.line(for:))).filter { !$0.isEmpty }.joined(separator: "\n")
                }
                if !content.isEmpty { append("assistant", ["type": "text", "text": content]) }
                for call in native {
                    append("assistant", ["type": "tool_use", "id": call.id, "name": call.name, "input": JSONValue.object(call.arguments).any])
                }
            case .tool(let callID, let name, let content):
                if wire == .native, !callID.hasPrefix(TextToolProtocol.callIDPrefix) {
                    append("user", ["type": "tool_result", "tool_use_id": callID, "content": content])
                } else {
                    append("user", ["type": "text", "text": TextToolProtocol.resultText(name: name, callID: callID, content: content)])
                }
            }
        }
        flush()
        if wire == .text, !tools.isEmpty { system.append(TextToolProtocol.render(tools)) }
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": turns]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if wire == .native, !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.any] as [String: Any] }
        }
        return body
    }

    // MARK: - Reply

    static func turn(from root: [String: Any], wire: AgentToolWire) throws -> AgentTurn {
        let blocks = root["content"] as? [[String: Any]] ?? []
        let finish = root["stop_reason"] as? String
        var text = CloudPlanner.stripThinking(CloudPlanner.contentText(blocks))
        var calls = blocks.enumerated().compactMap { index, block -> AgentToolCall? in
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
            let id = (block["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "toolu-\(index + 1)"
            return AgentToolCall(id: id, name: name, arguments: JSONValue(any: block["input"]).objectValue ?? [:])
        }
        var usedWire = wire
        if calls.isEmpty, !text.isEmpty {
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
            AppLog.assistant.info("housekeeper reply had no text: keys=\(root.keys.sorted().joined(separator: ","), privacy: .public) finish=\(finish ?? "none", privacy: .public)")
            if let finish, CloudPlanner.truncationReasons.contains(finish) { throw AgentTransportError.failed(CloudPlanner.outOfTokensMessage) }
            throw AgentTransportError.failed(CloudPlanner.emptyReplyMessage)
        }
        return AgentTurn(text: text, toolCalls: calls, reasoning: nil, finishReason: finish, usage: AgentHTTP.usage(from: root), wire: usedWire)
    }
}

/// Picks the transport for the configured Cloud LLM provider (nil when none).
@MainActor
public enum AgentTransportFactory {
    public static func make(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore(),
                            session: URLSession = CloudPlanner.makeSession(),
                            requestTimeout: TimeInterval = AppSettings.housekeeperRequestTimeout(),
                            preferred: AppSettings.ToolCallMode? = nil) -> AgentTransport? {
        switch AppSettings.plannerProvider(from: defaults) {
        case .anthropic:
            return AnthropicAgentTransport(defaults: defaults, secrets: secrets, session: session, requestTimeout: requestTimeout, preferred: preferred)
        case .openAICompatible:
            return OpenAIAgentTransport(defaults: defaults, secrets: secrets, session: session, requestTimeout: requestTimeout, preferred: preferred)
        case .none, .apple:
            return nil
        }
    }
}

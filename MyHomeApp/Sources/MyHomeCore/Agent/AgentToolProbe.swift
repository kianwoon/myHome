// One tiny round trip that learns whether the configured provider passes
// native tool calls through, or whether the text protocol is needed. The
// result is recorded in UserDefaults (shown by Test connection) and used as
// the starting wire for the agent; the transports still fall back on their own.
import Foundation

@MainActor
public enum AgentToolProbe {
    public enum Outcome: Equatable, Sendable {
        case native
        case text
        /// The model answered but never called the tool either way.
        case noToolCall(String)
        case failed(String)

        public var wire: AgentToolWire? {
            switch self {
            case .native: return .native
            case .text: return .text
            default: return nil
            }
        }

        public var summary: String {
            switch self {
            case .native: return "Tool calls: native function calling works."
            case .text: return "Tool calls: native calls are not returned; the text protocol works."
            case .noToolCall(let text): return "Tool calls: the model did not call the test tool (it replied: \(text))."
            case .failed(let reason): return "Tool calls: probe failed (\(reason))."
            }
        }
    }

    static let toolName = "ping"
    // allow-hardcode: probe prompt (test fixture text sent to the model).
    static let systemPrompt = "You are a tool-calling test. You MUST call the tool named ping exactly once (it takes no arguments), then reply with the single word OK."
    static let userPrompt = "Please call ping now."

    public static var tool: AgentToolDefinition {
        AgentToolDefinition(name: toolName, description: "Test tool. Call it once with no arguments.",
                            parameters: .object(["type": .string("object"), "properties": .object([:])]))
    }

    /// Native first, then an explicit text-protocol attempt. `make` builds a
    /// fresh transport for the wire asked for.
    public static func run(make: (AppSettings.ToolCallMode) -> AgentTransport?) async -> Outcome {
        guard let native = make(.native) else { return .failed("no Cloud LLM provider is configured") }
        let messages: [AgentMessage] = [.system(systemPrompt), .user(userPrompt)]
        var lastText = ""
        do {
            let turn = try await native.complete(messages, tools: [tool])
            if turn.toolCalls.contains(where: { $0.name == toolName }) { return turn.wire == .native ? .native : .text }
            lastText = turn.text
        } catch let error as AgentTransportError {
            if case .unavailable = error { return .failed(error.message) }
            lastText = error.message
            if case .cancelled = error { return .failed(error.message) }
        } catch {
            lastText = error.localizedDescription
        }
        guard let text = make(.text) else { return .failed("no Cloud LLM provider is configured") }
        do {
            let turn = try await text.complete(messages, tools: [tool])
            if turn.toolCalls.contains(where: { $0.name == toolName }) { return .text }
            return .noToolCall(String(turn.text.prefix(120)))
        } catch let error as AgentTransportError {
            return .failed(lastText.isEmpty ? error.message : "\(lastText); text protocol: \(error.message)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Runs the probe on the configured provider and records the outcome.
    public static func runAndRecord(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore(),
                                    session: URLSession = CloudPlanner.makeSession()) async -> Outcome {
        let timeout = AppSettings.housekeeperRequestTimeout(from: defaults)
        let outcome = await run { mode in
            let transport = AgentTransportFactory.make(defaults: defaults, secrets: secrets, session: session, requestTimeout: timeout, preferred: mode)
            (transport as? OpenAIAgentTransport)?.maxTokensOverride = AppSettings.housekeeperProbeMaxTokens
            (transport as? AnthropicAgentTransport)?.maxTokensOverride = AppSettings.housekeeperProbeMaxTokens
            return transport
        }
        let provider = AppSettings.plannerProvider(from: defaults)
        let model = provider.isCloud ? AppSettings.plannerModel(for: provider, from: defaults) : ""
        if let wire = outcome.wire { AppSettings.recordHousekeeperProbe(mode: wire.rawValue, model: model, in: defaults) }
        AppLog.assistant.notice("housekeeper tool probe: \(outcome.summary, privacy: .public)")
        return outcome
    }
}

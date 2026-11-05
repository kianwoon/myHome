// The chat-with-tools contract the housekeeper agent speaks to a model.
// One `complete` call = one model turn: the conversation so far plus the
// tool definitions in, assistant text and/or tool calls out. Transports
// (OpenAI-compatible, Anthropic) map these types onto their wire shapes and
// decide how tool calls travel (native function calling or the text
// protocol in TextToolProtocol.swift); the agent loop never sees the wire.
import Foundation

/// A JSON value with Sendable/Equatable semantics (tool arguments, schemas).
public enum JSONValue: Equatable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// From the result of JSONSerialization (Any); unknown shapes become null.
    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let string as String: self = .string(string)
        case let bool as Bool where Self.isBoolean(any): self = .bool(bool)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let array as [Any]: self = .array(array.map { JSONValue(any: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    /// NSNumber hides booleans: a CFBoolean is a Bool, everything else a number.
    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Back to a JSONSerialization-ready tree.
    public var any: Any {
        switch self {
        case .string(let string): return string
        case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? Int(number) : number
        case .bool(let bool): return bool
        case .null: return NSNull()
        case .array(let items): return items.map(\.any)
        case .object(let object): return object.mapValues(\.any)
        }
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let number): return number
        case .string(let string): return Double(string.trimmingCharacters(in: .whitespaces))
        case .bool(let bool): return bool ? 1 : 0
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let bool): return bool
        case .number(let number): return number != 0
        case .string(let string): return DPSValue.string(string).boolValue
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Compact JSON text (sorted keys, so tests and logs are stable).
    public var jsonText: String {
        guard JSONSerialization.isValidJSONObject(any) || !(any is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// Parses JSON text into a value (nil when the text is not JSON).
    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: object)
    }
}

/// One callable tool as the model sees it (JSON-schema parameters).
public struct AgentToolDefinition: Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A tool invocation the model asked for.
public struct AgentToolCall: Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let arguments: [String: JSONValue]

    public init(id: String, name: String, arguments: [String: JSONValue]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Short log/diagnostic form: `set {"action":"level","handles":[…]}`.
    public var summary: String { "\(name) \(JSONValue.object(arguments).jsonText)" }
}

/// Conversation entries in provider-neutral form.
public enum AgentMessage: Equatable, Sendable {
    case system(String)
    case user(String)
    /// `reasoning` is the provider's hidden-reasoning text when it must be
    /// echoed back on later turns (DeepSeek thinking mode); nil otherwise.
    case assistant(text: String, toolCalls: [AgentToolCall], reasoning: String?)
    /// A tool's result, keyed to the call it answers.
    case tool(callID: String, name: String, content: String)

    public static func assistant(_ text: String) -> AgentMessage { .assistant(text: text, toolCalls: [], reasoning: nil) }
}

public struct AgentUsage: Equatable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?

    public init(promptTokens: Int?, completionTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    public var summary: String {
        "prompt=\(promptTokens.map(String.init) ?? "?") completion=\(completionTokens.map(String.init) ?? "?")"
    }
}

/// How the tool calls of a turn travelled.
public enum AgentToolWire: String, Equatable, Sendable {
    case native, text
}

/// What one model turn produced. `text` is the visible reply (hidden
/// reasoning and tool-call lines removed); `toolCalls` are the requests.
public struct AgentTurn: Equatable, Sendable {
    public var text: String
    public var toolCalls: [AgentToolCall]
    public var reasoning: String?
    public var finishReason: String?
    public var usage: AgentUsage?
    public var wire: AgentToolWire

    public init(text: String, toolCalls: [AgentToolCall] = [], reasoning: String? = nil, finishReason: String? = nil,
                usage: AgentUsage? = nil, wire: AgentToolWire = .native) {
        self.text = text
        self.toolCalls = toolCalls
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.usage = usage
        self.wire = wire
    }
}

/// Why a transport could not complete a turn. Messages are key-free and
/// safe to show; `unavailable` means nothing was sent (configuration).
public enum AgentTransportError: Error, Equatable {
    case unavailable(String)
    case failed(String)
    case cancelled

    public var message: String {
        switch self {
        case .unavailable(let text), .failed(let text): return text
        case .cancelled: return "cancelled"
        }
    }
}

/// Implemented by the OpenAI-compatible and Anthropic transports; tests use
/// a scripted one. `complete` must honour task cancellation.
@MainActor
public protocol AgentTransport: AnyObject {
    /// Human-readable availability note (nil when a request can be sent).
    var unavailableReason: String? { get }
    /// The wire the transport is currently using for tool calls.
    var toolWire: AgentToolWire { get }
    /// Bound on one request; the agent sets it from its limits each turn.
    var requestTimeout: TimeInterval { get set }
    func complete(_ messages: [AgentMessage], tools: [AgentToolDefinition]) async throws -> AgentTurn
}

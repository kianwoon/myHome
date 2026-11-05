// What one housekeeper turn did, for the log and for last-reply.json: every
// tool call (name + arguments), each result summary, iterations, tokens, the
// tool-call wire and the final reply. The file lives in Application
// Support/MyHome so a verification run does not depend on log retention.
import Foundation

public struct AgentToolRecord: Equatable, Codable, Sendable {
    public let name: String
    public let arguments: String
    public let result: String
    public let milliseconds: Int

    public init(name: String, arguments: String, result: String, milliseconds: Int) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.milliseconds = milliseconds
    }
}

public struct AgentTrace: Equatable, Codable, Sendable {
    public static let resultSummaryLength = 1500

    public var utterance: String
    public var origin: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var wire: String?
    public var iterations = 0
    public var toolCalls: [AgentToolRecord] = []
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// reply / ask / needsConfirmation / failed
    public var outcome = ""
    public var replyText = ""
    public var error: String?

    public init(utterance: String, origin: String, startedAt: Date) {
        self.utterance = utterance
        self.origin = origin
        self.startedAt = startedAt
    }

    public mutating func add(usage: AgentUsage?) {
        guard let usage else { return }
        if let prompt = usage.promptTokens { promptTokens = (promptTokens ?? 0) + prompt }
        if let completion = usage.completionTokens { completionTokens = (completionTokens ?? 0) + completion }
    }

    public mutating func record(_ call: AgentToolCall, result: String, milliseconds: Int) {
        toolCalls.append(AgentToolRecord(name: call.name, arguments: JSONValue.object(call.arguments).jsonText,
                                         result: String(result.prefix(Self.resultSummaryLength)), milliseconds: milliseconds))
    }

    public var summary: String {
        "outcome=\(outcome) wire=\(wire ?? "none") iterations=\(iterations) toolCalls=\(toolCalls.count) tokens(prompt=\(promptTokens.map(String.init) ?? "?") completion=\(completionTokens.map(String.init) ?? "?"))"
    }
}

/// The last reply of the assistant, whatever produced it.
public struct LastReplyRecord: Equatable, Codable, Sendable {
    public var timestamp: Date
    public var utterance: String
    public var origin: String
    public var kind: String
    public var source: String
    public var text: String
    public var trace: AgentTrace?

    public init(timestamp: Date, utterance: String, origin: String, kind: String, source: String, text: String, trace: AgentTrace?) {
        self.timestamp = timestamp
        self.utterance = utterance
        self.origin = origin
        self.kind = kind
        self.source = source
        self.text = text
        self.trace = trace
    }
}

public enum LastReplyStore {
    public static func defaultURL() -> URL? {
        BridgeClient.bundledDataDirectory()?.appendingPathComponent(AppSettings.lastReplyFileName)
    }

    @discardableResult
    public static func write(_ record: LastReplyRecord, to url: URL? = defaultURL()) -> Bool {
        guard let url else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: url, options: .atomic)
            return true
        } catch {
            AppLog.assistant.error("last-reply write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func read(from url: URL? = defaultURL()) -> LastReplyRecord? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LastReplyRecord.self, from: data)
    }
}

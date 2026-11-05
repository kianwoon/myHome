// The housekeeper's short-term memory: the last few user/assistant turns
// (with a one-line note of what each turn did), kept while the conversation
// is active and dropped after a silence, so "a bit lower" and "and the fan"
// follow on from the previous request. The open question from ask_user
// lives here too, so the next utterance is read as its answer.
import Foundation

public struct ConversationMemory: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        public let user: String
        public let assistant: String
        /// What the turn did, in handle form ("set level 50: light-8e6d, light-931d").
        public let actions: [String]
        public let at: Date
    }

    public var maxTurns: Int
    public var idleTimeout: TimeInterval
    public private(set) var turns: [Turn] = []
    public private(set) var lastActivity: Date?
    /// The question the assistant is waiting on (ask_user), if any.
    public private(set) var pendingQuestion: String?

    public init(maxTurns: Int = AppSettings.defaultHousekeeperMemoryTurns, idleTimeout: TimeInterval = AppSettings.defaultHousekeeperMemoryIdle) {
        self.maxTurns = maxTurns
        self.idleTimeout = idleTimeout
    }

    public var isEmpty: Bool { turns.isEmpty && pendingQuestion == nil }

    /// Drops everything once the conversation has gone quiet.
    public mutating func expireIfIdle(now: Date) {
        guard let last = lastActivity, now.timeIntervalSince(last) > idleTimeout else { return }
        clear()
    }

    public mutating func clear() {
        turns = []
        pendingQuestion = nil
        lastActivity = nil
    }

    public mutating func record(user: String, assistant: String, actions: [String], at now: Date) {
        turns.append(Turn(user: user, assistant: assistant, actions: actions, at: now))
        if turns.count > maxTurns { turns.removeFirst(turns.count - maxTurns) }
        if maxTurns == 0 { turns = [] }
        lastActivity = now
        pendingQuestion = nil
    }

    public mutating func ask(_ question: String, after user: String, actions: [String], at now: Date) {
        record(user: user, assistant: question, actions: actions, at: now)
        pendingQuestion = question
    }

    public mutating func touch(at now: Date) { lastActivity = now }

    /// The open question is dropped (cancelled, or superseded by a new command).
    public mutating func withdrawQuestion() { pendingQuestion = nil }

    /// The remembered turns as messages for the model (oldest first).
    public func messages() -> [AgentMessage] {
        turns.flatMap { turn -> [AgentMessage] in
            var reply = turn.assistant
            if !turn.actions.isEmpty { reply += "\n(did: " + turn.actions.joined(separator: "; ") + ")" }
            return [.user(turn.user), .assistant(reply)]
        }
    }
}

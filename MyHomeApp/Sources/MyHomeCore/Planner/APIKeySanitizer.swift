// One shared clean-up and validity check for every pasted API key (Jev and the
// cloud planner). A key with whitespace/control characters in the middle is never
// sent and never "repaired": it is classified so the UI can say exactly what is
// wrong. Nothing here ever returns or logs the key text in a message.
import Foundation

public enum APIKeySanitizer {
    public enum Invalid: String, Equatable, Sendable {
        case empty, multiLine, internalWhitespace, controlCharacters, nonASCII
    }

    public struct Outcome: Equatable, Sendable {
        /// The key to store/send; nil exactly when `invalid` is set.
        public let key: String?
        public let invalid: Invalid?
        /// Edits made to the pasted value (for the "Removed a leading Bearer" note).
        public let removedBearerPrefix: Bool
        public let removedQuotes: Bool
        /// Characters of the pasted value after trimming its ends, and whitespace-separated pieces.
        public let rawLength: Int
        public let tokenCount: Int

        public var wasEdited: Bool { removedBearerPrefix || removedQuotes }
    }

    // allow-hardcode: header names and prefixes of the wire format being stripped.
    private static let authorizationHeader = "authorization:"
    private static let bearerWord = "bearer"

    public static func sanitize(_ raw: String) -> Outcome {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        var text = trimmed
        var bearer = false
        var quotes = false
        for _ in 0..<2 {   // order-insensitive: "Bearer 'k'", "'Bearer k'", "Authorization: Bearer k"
            if text.lowercased().hasPrefix(authorizationHeader) {
                text = String(text.dropFirst(authorizationHeader.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if text.lowercased().hasPrefix(bearerWord), text.count > bearerWord.count,
               let next = text.dropFirst(bearerWord.count).first, next.isWhitespace {
                text = String(text.dropFirst(bearerWord.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                bearer = true
            }
            if text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                quotes = true
            }
        }
        if text.lowercased() == bearerWord { text = "" }   // only the word was pasted
        let reason = classify(text)
        return Outcome(key: reason == nil ? text : nil, invalid: reason, removedBearerPrefix: bearer,
                       removedQuotes: quotes, rawLength: trimmed.count, tokenCount: tokens)
    }

    static func classify(_ text: String) -> Invalid? {
        if text.isEmpty { return .empty }
        let scalars = text.unicodeScalars
        if scalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" || $0 == "\u{85}" }) { return .multiLine }
        if scalars.contains(where: { $0.properties.isWhitespace }) { return .internalWhitespace }
        if scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }) {
            return .controlCharacters
        }
        if scalars.contains(where: { $0.value > 0x7E }) { return .nonASCII }
        return nil
    }

    /// True when the value may be placed in an HTTP header: non-empty printable ASCII only.
    public static func isHeaderSafe(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E }
    }

    // MARK: Messages (never contain the key)

    /// At save time, shown inline under the key field.
    public static func saveMessage(for reason: Invalid) -> String {
        switch reason {
        case .empty: return "Nothing to save: the key field is empty."
        case .multiLine: return "That doesn't look like a single API key: it contains line breaks. Paste only the key itself."
        case .internalWhitespace: return "That doesn't look like a single API key: it contains spaces. Paste only the key itself."
        case .controlCharacters: return "That doesn't look like a single API key: it contains hidden control characters. Paste only the key itself."
        case .nonASCII: return "That doesn't look like a single API key: it contains non-ASCII characters. Paste only the key itself."
        }
    }

    // allow-hardcode: UI copy.
    public static let removedBearerNote = "Removed a leading \"Bearer \" from the pasted value."
    public static let removedQuotesNote = "Removed surrounding quotes from the pasted value."

    public static func editNote(for outcome: Outcome) -> String? {
        var notes: [String] = []
        if outcome.removedBearerPrefix { notes.append(removedBearerNote) }
        if outcome.removedQuotes { notes.append(removedQuotesNote) }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// For an already-saved invalid key, at call time (length and token count only).
    public static func savedMessage(for reason: Invalid, length: Int, tokens: Int, subject: String = "The saved API key") -> String {
        let what: String
        switch reason {
        case .empty: return "No API key is saved (paste one and press Save key)"
        case .multiLine, .internalWhitespace: what = "spaces or line breaks"
        case .controlCharacters: what = "hidden control characters"
        case .nonASCII: what = "non-ASCII characters"
        }
        return "\(subject) contains \(what) (\(length) characters, \(tokens) tokens) — paste only the key and press Save key"
    }
}

/// What kind of key a service expects, so a diagnostic can say "wrong kind of key"
/// without ever showing a prefix.
public struct KeyShapeClass: Equatable, Sendable {
    public let label: String
    public let prefix: String
    public static let openRouter = KeyShapeClass(label: "OpenRouter", prefix: "sk-or-")   // allow-hardcode: provider key shape
    public static let anthropic = KeyShapeClass(label: "Anthropic", prefix: "sk-ant-")    // allow-hardcode: provider key shape
    public static let openAI = KeyShapeClass(label: "OpenAI", prefix: "sk-")              // allow-hardcode: provider key shape

    /// "an OpenRouter key" / "a Foo key".
    public var phrase: String { "\(label.first.map { "AEIOU".contains($0) ? "an" : "a" } ?? "a") \(label) key" }

    public func matches(_ value: String) -> Bool { value.hasPrefix(prefix) }
}

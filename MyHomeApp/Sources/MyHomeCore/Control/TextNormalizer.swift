// Shared text normalisation for the device resolver and the Level-1 parser.
// Content-agnostic on purpose: lower-case, diacritic-fold, split on
// non-alphanumerics, naive singularisation. No phrase lists live here.
import Foundation

public enum TextNormalizer {
    /// Shortest token that is singularised; "gas"/"bus" style words stay.
    static let singularizeMinLength = 4

    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    /// Raw tokens: folded, split on anything that is not a letter or digit.
    public static func rawTokens(_ text: String) -> [String] {
        fold(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Naive English singular: "lights" → "light", "glass" stays.
    public static func singular(_ token: String) -> String {
        guard token.count >= singularizeMinLength, token.hasSuffix("s"), !token.hasSuffix("ss") else { return token }
        return String(token.dropLast())
    }

    public static func isPlural(_ token: String) -> Bool {
        singular(token) != token
    }

    /// Tokens ready for matching: singularised, stop words removed.
    public static func tokens(_ text: String, stopWords: Set<String> = []) -> [String] {
        rawTokens(text).map(singular).filter { !stopWords.contains($0) }
    }

    /// Canonical whole-string form for exact comparisons ("Study  Fan" == "study fan").
    public static func canonical(_ text: String) -> String {
        rawTokens(text).joined(separator: " ")
    }
}

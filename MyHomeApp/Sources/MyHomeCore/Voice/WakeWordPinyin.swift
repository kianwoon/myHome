// Chinese side of the wake phrase: characters → tone-marked pinyin (macOS's
// Mandarin transform) → the KWS model's units, an initial plus a tone-marked
// final ("小家" → x iǎo j iā). Users may also type pinyin for a character with
// several readings, tone-marked ("hēi") or numbered ("hei1").
import Foundation

public enum WakeWordPinyin {
    /// Two-letter initials first so "zh" wins over "z".
    static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
                           "j", "q", "x", "r", "z", "c", "s", "y", "w"]
    static let toneMarks: [Character: [Character]] = [
        "a": ["ā", "á", "ǎ", "à"], "e": ["ē", "é", "ě", "è"], "i": ["ī", "í", "ǐ", "ì"],
        "o": ["ō", "ó", "ǒ", "ò"], "u": ["ū", "ú", "ǔ", "ù"], "ü": ["ǖ", "ǘ", "ǚ", "ǜ"]
    ]
    static let markedVowels: Set<Character> = Set(toneMarks.values.flatMap { $0 })

    public static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// "嘿吼" → ["hēi", "hǒu"].
    public static func syllables(ofHan text: String) -> [String] {
        let buffer = NSMutableString(string: text)
        CFStringTransform(buffer, nil, kCFStringTransformMandarinLatin, false)
        return (buffer as String).lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// A typed word that is pinyin rather than English: carries a tone mark,
    /// a ü, or ends in a tone digit 1-5 ("hei1").
    public static func looksLikePinyin(_ word: String) -> Bool {
        let lower = word.lowercased()
        if lower.contains(where: { markedVowels.contains($0) || $0 == "ü" }) { return true }
        guard let last = lower.last, ("1"..."5").contains(last) else { return false }
        return lower.dropLast().allSatisfy { $0.isLetter && $0.isASCII || $0 == "v" }
    }

    /// "hei1" → "hēi", "lv4" → "lǜ"; tone 5 / no digit = neutral (unmarked).
    public static func applyToneNumber(_ syllable: String) -> String {
        var text = syllable.lowercased().replacingOccurrences(of: "v", with: "ü")
        guard let last = text.last, let tone = Int(String(last)), (1...5).contains(tone) else { return text }
        text.removeLast()
        guard tone < 5 else { return text }
        let chars = Array(text)
        // Standard placement: a or e takes the mark; else the o of "ou"; else the last vowel.
        let target: Int? = chars.firstIndex(of: "a") ?? chars.firstIndex(of: "e")
            ?? (text.contains("ou") ? chars.firstIndex(of: "o") : nil)
            ?? chars.lastIndex(where: { toneMarks[$0] != nil })
        guard let index = target, let marks = toneMarks[chars[index]] else { return text }
        var out = chars
        out[index] = marks[tone - 1]
        return String(out)
    }

    /// "xiǎo" → ["x", "iǎo"], "ér" → ["ér"]. The model writes ü as u after
    /// j/q/x/y, as pinyin does ("jū"), so no rewrite is needed there.
    public static func units(ofSyllable syllable: String) -> [String] {
        let lower = syllable.lowercased()
        for initial in initials where lower.hasPrefix(initial) && lower.count > initial.count {
            return [initial, String(lower.dropFirst(initial.count))]
        }
        return [lower]
    }
}

// A wake-started utterance often begins with the wake phrase itself (the
// user said "Hey Home, lights off" in one breath, or repeated "Hey Home"
// after the chime). The recogniser's spelling varies by engine and accent
// ("Hey, home.", "Heyhome", "嘿，吼。", "嘿，home"), so matching is done on a
// punctuation- and space-free lowercase form against configured spellings.
import Foundation

public extension AppSettings {
    /// Transcript spellings of the wake phrase seen from Qwen3-ASR /
    /// SenseVoice on a real voice (normalised: lowercase, no spaces/punctuation).
    static let wakePhraseSpellingsKey = "wakePhraseSpellings"
    static let defaultWakePhraseSpellings = ["heyhome", "heyhom", "heyhu", "嘿吼", "嘿home", "嘿好", "嘿hom", "嘿hu"]
    /// No speech this long after a wake ends the session silently (a false
    /// wake must not hold the speakers muted for the full Settings timeout).
    static let wakeNoSpeechTimeoutKey = "wakeNoSpeechTimeoutSeconds"
    static let defaultWakeNoSpeechTimeout: Double = 4
    static let wakeNoSpeechTimeoutRange: ClosedRange<Double> = 2...15

    static func wakePhraseSpellings(from defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.stringArray(forKey: wakePhraseSpellingsKey) ?? []
        return stored.isEmpty ? defaultWakePhraseSpellings : stored
    }

    static func wakeNoSpeechTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        speechClamp(defaults, wakeNoSpeechTimeoutKey, defaultWakeNoSpeechTimeout, wakeNoSpeechTimeoutRange)
    }
}

public enum WakePhraseStripper {
    /// The command after any leading wake phrase(s); "" when the utterance
    /// was only the wake phrase.
    public static func command(from utterance: String,
                               spellings: [String] = AppSettings.wakePhraseSpellings()) -> String {
        let keep = { (c: Character) in c.isLetter || c.isNumber }
        // Map each kept character back to its index in the original text.
        var normal: [Character] = []
        var origin: [String.Index] = []
        for index in utterance.indices where keep(utterance[index]) {
            normal.append(Character(utterance[index].lowercased()))
            origin.append(index)
        }
        let forms = spellings.map { Array($0.lowercased().filter(keep)) }.filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        var cut = 0
        var matched = true
        while matched {
            matched = false
            for form in forms where cut + form.count <= normal.count && Array(normal[cut..<(cut + form.count)]) == form {
                cut += form.count
                matched = true
                break
            }
        }
        guard cut > 0 else { return utterance.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cut < normal.count else { return "" }
        let rest = utterance[origin[cut]...]
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

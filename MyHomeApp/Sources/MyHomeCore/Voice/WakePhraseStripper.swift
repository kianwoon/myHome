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
    /// How long a wake waits for the command to start before ending silently.
    /// 4 s cut users off while they were still gathering the sentence; say a
    /// dismiss word ("ignore") to end it sooner.
    static let wakeNoSpeechTimeoutKey = "wakeNoSpeechTimeoutSeconds"
    static let defaultWakeNoSpeechTimeout: Double = 10
    static let wakeNoSpeechTimeoutRange: ClosedRange<Double> = 2...30
    /// A whole utterance that is one of these ends the session silently instead
    /// of reaching the assistant (normalised: lowercase, letters/digits only).
    static let voiceDismissWordsKey = "voiceDismissWords"
    static let defaultVoiceDismissWords = ["ignore", "dismiss", "cancel", "never mind", "nevermind", "forget it",
                                           "stop listening", "nothing", "算了", "取消", "不用了", "没事", "不用"]

    static func voiceDismissWords(from defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.stringArray(forKey: voiceDismissWordsKey) ?? []
        return stored.isEmpty ? defaultVoiceDismissWords : stored
    }

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

/// "Ignore." / "Dismiss!" / "算了。" — the user closing the session, not a command.
public enum VoiceDismiss {
    static func normalise(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    public static func isDismissal(_ utterance: String, words: [String] = AppSettings.voiceDismissWords()) -> Bool {
        let said = normalise(utterance)
        guard !said.isEmpty else { return false }
        return words.contains { normalise($0) == said }
    }
}

// Config for the always-on wake word ("Hey Home"). Same pattern as
// SpeechSettings: named defaults + UserDefaults override keys, clamped. The
// keyword-spotting model identity and its size floors live here, so the
// spotter files carry no bare literal.
import Foundation

public extension AppSettings {
    /// Opt-in: always-on listening keeps the macOS microphone indicator lit.
    static let wakeWordEnabledKey = "wakeWordEnabled"
    static let defaultWakeWordEnabled = false
    /// English words, each looked up in the model's pronunciation lexicon.
    static let wakeWordPhraseKey = "wakeWordPhrase"
    static let defaultWakeWordPhrase = "HEY HOME"
    /// Detection threshold: higher = fewer false wakes, more misses. Tuned
    /// on a real voice (warm room audio): 0.1 gave 4-5/5 recall with zero
    /// false wakes once trailing blanks are 4; 0.25 already drops to 1-2/5.
    /// New key: the first preview's slider stored values from a decaying
    /// spotter (e.g. 0.38) that would silence detection.
    static let wakeWordThresholdKey = "wakeWordThresholdV2"
    static let defaultWakeWordThreshold: Double = 0.1
    static let wakeWordThresholdRange: ClosedRange<Double> = 0.03...0.3
    /// Boost for the phrase's tokens: higher = easier to trigger.
    static let wakeWordBoostKey = "wakeWordBoost"
    static let defaultWakeWordBoost: Double = 1.5
    static let wakeWordBoostRange: ClosedRange<Double> = 0.5...5
    /// After a wake (or a resume) further detections are ignored this long.
    static let wakeWordCooldownKey = "wakeWordCooldownSeconds"
    static let defaultWakeWordCooldown: Double = 1.0
    static let wakeWordCooldownRange: ClosedRange<Double> = 0...10
    /// Grace after the reply finishes before the mic re-arms (room echo).
    static let wakeWordResumeDelayKey = "wakeWordResumeDelaySeconds"
    static let defaultWakeWordResumeDelay: Double = 0.6
    static let wakeWordResumeDelayRange: ClosedRange<Double> = 0...5
    /// System sound played on a wake, so the user knows when to speak.
    static let wakeWordChimeKey = "wakeWordChime"
    static let defaultWakeWordChime = "Tink"

    /// Longest a transient pause (recogniser, reply, assistant) may hold the
    /// wake word before it is released anyway. Above the 30 s utterance cap
    /// plus a long spoken reply.
    static let wakeWordMaxPauseKey = "wakeWordMaxPauseSeconds"
    static let defaultWakeWordMaxPause: Double = 90
    static let wakeWordMaxPauseRange: ClosedRange<Double> = 10...600

    static func wakeWordMaxPause(from defaults: UserDefaults = .standard) -> TimeInterval {
        speechClamp(defaults, wakeWordMaxPauseKey, defaultWakeWordMaxPause, wakeWordMaxPauseRange)
    }

    static func wakeWordEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: wakeWordEnabledKey) as? Bool ?? defaultWakeWordEnabled
    }

    static func wakeWordPhrase(from defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: wakeWordPhraseKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultWakeWordPhrase : stored
    }

    static func wakeWordThreshold(from defaults: UserDefaults = .standard) -> Double {
        speechClamp(defaults, wakeWordThresholdKey, defaultWakeWordThreshold, wakeWordThresholdRange)
    }

    static func wakeWordBoost(from defaults: UserDefaults = .standard) -> Double {
        speechClamp(defaults, wakeWordBoostKey, defaultWakeWordBoost, wakeWordBoostRange)
    }

    static func wakeWordCooldown(from defaults: UserDefaults = .standard) -> TimeInterval {
        speechClamp(defaults, wakeWordCooldownKey, defaultWakeWordCooldown, wakeWordCooldownRange)
    }

    static func wakeWordResumeDelay(from defaults: UserDefaults = .standard) -> TimeInterval {
        speechClamp(defaults, wakeWordResumeDelayKey, defaultWakeWordResumeDelay, wakeWordResumeDelayRange)
    }

    static func wakeWordChime(from defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: wakeWordChimeKey) ?? defaultWakeWordChime
    }
}

/// The sherpa-onnx streaming keyword-spotting model (zipformer, Chinese +
/// English, phone tokens with an English lexicon).
public enum WakeWordModelSpec {
    // allow-hardcode: upstream release location of the sherpa-onnx KWS models
    // (the same project MyHome's ASR models come from) — config data.
    public static let releaseBaseURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models"
    public static let archiveName = "sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20"
    public static let archiveExtension = "tar.bz2"
    public static let directoryName = "kws"
    public static let approxDownloadMB = 33

    // The 16-frame-chunk INT8 variant: lower CPU than chunk-8, adequate latency.
    public static let encoderFile = "encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx"
    public static let decoderFile = "decoder-epoch-13-avg-2-chunk-16-left-64.onnx"
    public static let joinerFile = "joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx"
    public static let tokensFile = "tokens.txt"
    public static let lexiconFile = "en.phone"

    static let minEncoderBytes = 1 * SpeechModelSpec.mebibyte
    static let minDecoderBytes = 64 * 1024
    static let minJoinerBytes = 16 * 1024
    static let minTokensBytes = 512
    static let minLexiconBytes = 1 * SpeechModelSpec.mebibyte

    static let inferenceThreads = 1
    static let maxActivePaths = 16
    /// Blank frames required after the phrase: 4 rejects "Hey Homer" / "Hey
    /// Hong Kong" (phrase + more speech) at no recall cost; 1-2 accept them.
    static let numTrailingBlanks = 4
    /// Name the detection is reported under (`@NAME` in the keywords buffer).
    public static let keywordTag = "WAKE"
}

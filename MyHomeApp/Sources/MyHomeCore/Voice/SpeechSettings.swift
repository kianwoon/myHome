// Config for the offline speech-to-text layer (modelled on the Pop app's ring
// chain). Same pattern as AppSettings: named defaults + UserDefaults override
// keys, clamped to a sane range. Model names, download locations and asset
// size floors live here too, so no engine file carries a bare literal.
import Foundation

/// The offline STT engines, best first. Apple's SFSpeechRecognizer is NOT a
/// member: like Pop, MyHome's speech runs only on models it can gate itself.
public enum SpeechEngineKind: String, CaseIterable, Sendable, Identifiable {
    /// Qwen3-ASR-0.6B (sherpa-onnx INT8) — Pop's pinned, tested primary ring.
    case qwenAsr
    /// SenseVoice (sherpa-onnx INT8) — Pop's fallback ring.
    case senseVoice

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .qwenAsr: return "Qwen3-ASR"
        case .senseVoice: return "SenseVoice"
        }
    }
}

public extension AppSettings {
    // MARK: Engine choice

    /// "" = automatic (the natural chain qwenAsr → senseVoice); otherwise a
    /// `SpeechEngineKind.rawValue` tried first. A pin is policy, not a bypass:
    /// an ineligible pinned engine falls back to the chain.
    static let speechPreferredEngineKey = "speechPreferredEngine"
    static let defaultSpeechPreferredEngine = SpeechEngineKind.qwenAsr.rawValue
    /// Qwen3-ASR decode backend: "mlx" (Apple GPU, default) or "onnx" (sherpa-onnx INT8, CPU); (Apple
    /// GPU, needs the MLX model installed; any failure falls back to "onnx").
    static let speechQwenBackendKey = "speechQwenBackend"
    static let speechBackendOnnx = "onnx"
    static let speechBackendMlx = "mlx"
    static let defaultSpeechQwenBackend = speechBackendMlx
    static let speechQwenAsrEnabledKey = "speechQwenAsrEnabled"
    static let defaultSpeechQwenAsrEnabled = true
    static let speechSenseVoiceEnabledKey = "speechSenseVoiceEnabled"
    static let defaultSpeechSenseVoiceEnabled = true
    /// Tell Qwen3-ASR which language to expect (the voice locale's). Without it
    /// the engine auto-detects, and short accented clips can come back as
    /// another language. Turn off to speak several languages.
    static let speechQwenPinLanguageKey = "speechQwenPinLanguage"
    static let defaultSpeechQwenPinLanguage = true
    /// Pass device and room names to Qwen3-ASR as hotwords.
    static let speechHotwordBiasKey = "speechHotwordBias"
    /// Off by default: with a long device list Qwen3-ASR echoes the list back
    /// as the transcript. Opt-in only.
    static let defaultSpeechHotwordBias = false
    /// At most this many hotwords are passed (the decoder prompt is bounded;
    /// a long list invites the decoder to echo it).
    static let speechMaxHotwords = 16
    /// Echo guard: a transcript is rejected when this many distinct hotwords
    /// appear in it...
    static let speechEchoMinDistinctHotwords = 3
    /// ...and they cover at least this fraction of its characters.
    static let speechEchoCoverage = 0.6
    /// Hotwords shorter than this are ignored by the echo guard.
    static let speechEchoMinHotwordLength = 3
    /// Characters per audio second above which a transcript is implausible.
    static let speechMaxCharsPerSecond = 30.0
    /// Also look for models installed by the Pop app (read-only).
    static let speechUsePopModelsKey = "speechUsePopModels"
    static let defaultSpeechUsePopModels = true

    // MARK: VAD (Pop's dictation profile)

    static let speechVADThresholdKey = "speechVADThreshold"
    static let defaultSpeechVADThreshold: Double = 0.5
    static let speechVADThresholdRange: ClosedRange<Double> = 0.1...0.95

    /// Silence that closes one VAD segment.
    static let speechVADMinSilenceKey = "speechVADMinSilenceSeconds"
    static let defaultSpeechVADMinSilence: Double = 0.35
    static let speechVADMinSilenceRange: ClosedRange<Double> = 0.1...2

    static let speechVADMinSpeechKey = "speechVADMinSpeechSeconds"
    static let defaultSpeechVADMinSpeech: Double = 0.25
    static let speechVADMinSpeechRange: ClosedRange<Double> = 0.05...2

    static let speechVADMaxSpeechKey = "speechVADMaxSpeechSeconds"
    static let defaultSpeechVADMaxSpeech: Double = 10
    static let speechVADMaxSpeechRange: ClosedRange<Double> = 2...30

    /// Audio kept before a detected onset and prepended to the segment.
    static let speechPreRollKey = "speechPreRollSeconds"
    static let defaultSpeechPreRoll: Double = 0.5
    static let speechPreRollRange: ClosedRange<Double> = 0...2

    // MARK: Endpointing / bounded timeouts

    /// After a segment is transcribed, end the utterance once no new speech
    /// starts within this window (push-to-talk dictation endpoint).
    static let speechEndpointHangoverKey = "speechEndpointHangoverSeconds"
    static let defaultSpeechEndpointHangover: Double = 1.2
    static let speechEndpointHangoverRange: ClosedRange<Double> = 0...5
    /// Extra wait when the last words look unfinished ("...and", trailing comma).
    static let speechIncompleteExtensionKey = "speechIncompleteExtensionSeconds"
    static let defaultSpeechIncompleteExtension: Double = 1.0
    static let speechIncompleteExtensionRange: ClosedRange<Double> = 0...5

    /// End a session in which no speech was ever detected.
    static let speechNoSpeechTimeoutKey = "speechNoSpeechTimeoutSeconds"
    static let defaultSpeechNoSpeechTimeout: Double = 8
    static let speechNoSpeechTimeoutRange: ClosedRange<Double> = 2...60

    /// Bound on decoding what is still buffered after capture stops.
    static let speechFlushTimeoutKey = "speechFlushTimeoutSeconds"
    static let defaultSpeechFlushTimeout: Double = 6
    static let speechFlushTimeoutRange: ClosedRange<Double> = 1...30

    /// Bound on constructing a recognizer (Qwen3-ASR loads ~1 GB).
    static let speechModelLoadTimeoutKey = "speechModelLoadTimeoutSeconds"
    static let defaultSpeechModelLoadTimeout: Double = 45
    static let speechModelLoadTimeoutRange: ClosedRange<Double> = 5...180

    /// Pop's permission-handshake watchdog.
    static let speechHandshakeTimeoutKey = "speechHandshakeTimeoutSeconds"
    static let defaultSpeechHandshakeTimeout: Double = 10
    static let speechHandshakeTimeoutRange: ClosedRange<Double> = 2...60

    /// Pop's liveness probe: an engine that processed nothing while at least
    /// `speechDeadVerdictNonSilentSeconds` of audible input flowed is dead.
    static let speechLivenessIntervalKey = "speechLivenessIntervalSeconds"
    static let defaultSpeechLivenessInterval: Double = 5
    static let speechLivenessIntervalRange: ClosedRange<Double> = 1...30
    static let speechDeadVerdictNonSilentSeconds: Double = 1
    /// Peak sample magnitude above which a buffer counts as audible.
    static let speechAudiblePeakThreshold: Float = 0.01

    static func speechPreferredEngine(from defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: speechPreferredEngineKey) ?? defaultSpeechPreferredEngine
    }

    static func speechEngineEnabled(_ kind: SpeechEngineKind, from defaults: UserDefaults = .standard) -> Bool {
        switch kind {
        case .qwenAsr: return defaults.object(forKey: speechQwenAsrEnabledKey) as? Bool ?? defaultSpeechQwenAsrEnabled
        case .senseVoice: return defaults.object(forKey: speechSenseVoiceEnabledKey) as? Bool ?? defaultSpeechSenseVoiceEnabled
        }
    }

    static func speechQwenBackend(from defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: speechQwenBackendKey) ?? defaultSpeechQwenBackend
        return value == speechBackendOnnx ? speechBackendOnnx : speechBackendMlx
    }

    static func speechHotwordBias(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: speechHotwordBiasKey) as? Bool ?? defaultSpeechHotwordBias
    }

    static func speechUsePopModels(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: speechUsePopModelsKey) as? Bool ?? defaultSpeechUsePopModels
    }

    static func speechVADProfile(from defaults: UserDefaults = .standard) -> VADProfile {
        VADProfile(
            threshold: Float(speechClamp(defaults, speechVADThresholdKey, defaultSpeechVADThreshold, speechVADThresholdRange)),
            minSilenceSeconds: Float(speechClamp(defaults, speechVADMinSilenceKey, defaultSpeechVADMinSilence, speechVADMinSilenceRange)),
            minSpeechSeconds: Float(speechClamp(defaults, speechVADMinSpeechKey, defaultSpeechVADMinSpeech, speechVADMinSpeechRange)),
            maxSpeechSeconds: Float(speechClamp(defaults, speechVADMaxSpeechKey, defaultSpeechVADMaxSpeech, speechVADMaxSpeechRange)),
            preRollSeconds: Float(speechClamp(defaults, speechPreRollKey, defaultSpeechPreRoll, speechPreRollRange))
        )
    }

    static func speechEndpointPolicy(from defaults: UserDefaults = .standard) -> EndpointPolicy {
        EndpointPolicy(
            hangover: speechClamp(defaults, speechEndpointHangoverKey, defaultSpeechEndpointHangover, speechEndpointHangoverRange),
            noSpeechTimeout: speechClamp(defaults, speechNoSpeechTimeoutKey, defaultSpeechNoSpeechTimeout, speechNoSpeechTimeoutRange),
            maxUtterance: speechMaxUtterance(from: defaults),
            incompleteExtension: speechClamp(defaults, speechIncompleteExtensionKey, defaultSpeechIncompleteExtension, speechIncompleteExtensionRange)
        )
    }

    static func speechFlushTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        speechClamp(defaults, speechFlushTimeoutKey, defaultSpeechFlushTimeout, speechFlushTimeoutRange)
    }

    static func speechModelLoadTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        speechClamp(defaults, speechModelLoadTimeoutKey, defaultSpeechModelLoadTimeout, speechModelLoadTimeoutRange)
    }

    static func speechHandshakeTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        speechClamp(defaults, speechHandshakeTimeoutKey, defaultSpeechHandshakeTimeout, speechHandshakeTimeoutRange)
    }

    static func speechLivenessInterval(from defaults: UserDefaults = .standard) -> TimeInterval {
        speechClamp(defaults, speechLivenessIntervalKey, defaultSpeechLivenessInterval, speechLivenessIntervalRange)
    }

    /// Clamp a stored Double into `range`; a missing or non-finite value falls
    /// back to the default.
    static func speechClamp(_ defaults: UserDefaults, _ key: String, _ fallback: Double,
                            _ range: ClosedRange<Double>) -> Double {
        let stored = (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
        guard stored.isFinite else { return fallback }
        return min(max(stored, range.lowerBound), range.upperBound)
    }
}

/// Model identity, install locations and usability floors — the same assets
/// (and the same release location) the Pop app installs.
public enum SpeechModelSpec {
    // allow-hardcode: upstream release location of the sherpa-onnx ASR models
    // (the same one Pop downloads from) — config data, nothing user-specific
    // is ever sent there.
    public static let releaseBaseURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
    public static let qwenAsrArchiveName = "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
    public static let senseVoiceArchiveName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    public static let vadFileName = "silero_vad.onnx"
    public static let archiveExtension = "tar.bz2"
    /// Approximate download size per engine, for the install button copy.
    public static let approxDownloadMB = 1000

    /// MyHome's own install root (`~/Library/Application Support/MyHome/speech`).
    public static let appSupportFolder = "MyHome"
    public static let speechFolder = "speech"
    /// Pop's install root, searched read-only when `speechUsePopModels` is on.
    public static let popAppSupportFolder = "Pop"
    public static let tarPath = "/usr/bin/tar"

    public static func directoryName(_ kind: SpeechEngineKind) -> String {
        switch kind {
        case .qwenAsr: return "qwenasr"
        case .senseVoice: return "sensevoice"
        }
    }

    public static func archiveName(_ kind: SpeechEngineKind) -> String {
        switch kind {
        case .qwenAsr: return qwenAsrArchiveName
        case .senseVoice: return senseVoiceArchiveName
        }
    }

    // Size floors sit far below the real assets and far above an empty file or
    // an HTML error page (Pop's values), so a partial install is rejected
    // BEFORE sherpa-onnx's fatalError-on-bad-asset init.
    static let mebibyte = 1024 * 1024
    static let minQwenConvBytes = 20 * mebibyte
    static let minQwenEncoderBytes = 100 * mebibyte
    static let minQwenDecoderBytes = 300 * mebibyte
    static let minQwenVocabBytes = 64 * 1024
    static let minQwenMergesBytes = 64 * 1024
    static let minQwenVocabEntries = 1000
    static let minQwenMergeLines = 100
    static let minSenseVoiceModelBytes = 100 * mebibyte
    static let minSenseVoiceTokensBytes = 1024
    static let minVadBytes = 100 * 1024

    // Recognizer construction (Pop's values).
    static let sampleRate = 16000
    static let inferenceThreads = 2
    static let featureDim = 80
    static let vadWindowSize = 512
    /// sherpa-onnx opens a segment 2 windows (+ min speech) before detection;
    /// one more window covers the chunk in which detection happened.
    static let vadLookbackWindows = 3
    static let vadBufferSeconds: Float = 30
    static let qwenMaxTotalLen = 512
    static let qwenMaxNewTokens = 128
    static let qwenTemperature: Float = 1e-6
    static let qwenTopP: Float = 0.8
    static let qwenSeed = 42
}

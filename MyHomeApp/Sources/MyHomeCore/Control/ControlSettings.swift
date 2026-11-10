// Settings for the unified control layer, the voice adapters and the planner.
// Same pattern as AppSettings: named defaults + UserDefaults override keys,
// clamped to a sane range. Nothing in the control path reads a bare literal.
import Foundation

public extension AppSettings {
    // MARK: Controller

    static let commandVerifyTimeoutKey = "commandVerifyTimeoutSeconds"
    static let defaultCommandVerifyTimeout: TimeInterval = 3
    static let commandVerifyTimeoutRange: ClosedRange<TimeInterval> = 0.5...30

    /// A command touching at least this many devices asks before running.
    static let confirmDeviceCountKey = "confirmDeviceCountThreshold"
    static let defaultConfirmDeviceCount = 2
    static let confirmDeviceCountRange = 1...100

    /// Read-back tolerance for a percent level (brightness, position).
    static let verifyLevelToleranceKey = "commandVerifyLevelTolerance"
    static let defaultVerifyLevelTolerance = 10
    static let verifyLevelToleranceRange = 1...50
    /// A reading older than this is re-read before a command (pre-check).
    static let stateFreshnessKey = "commandStateFreshnessSeconds"
    static let defaultStateFreshness: TimeInterval = 30
    static let stateFreshnessRange: ClosedRange<TimeInterval> = 2...600
    /// Pause between read-back attempts while verifying a write.
    static let verifySettleKey = "commandVerifySettleSeconds"
    static let defaultVerifySettle: TimeInterval = 0.8
    static let verifySettleRange: ClosedRange<TimeInterval> = 0.1...10

    static let resolverAmbiguityMarginKey = "resolverAmbiguityMargin"
    static let defaultResolverAmbiguityMargin = 0.1
    static let resolverMinCoverageKey = "resolverMinCoverage"
    static let defaultResolverMinCoverage = 0.5
    static let unitFractionRange = 0.0...1.0

    /// "Fuzzy" matching: when no device matches a spoken name exactly, offer
    /// the near-misses (accent-caused misrecognitions) as suggestions.
    static let fuzzyMatchKey = "fuzzyDeviceMatch"
    static let defaultFuzzyMatch = true
    /// Words shorter than this are never fuzzy-matched.
    static let defaultFuzzyMinTokenLength = 4
    /// Edit distance allowed, as a fraction of the longer word's length.
    static let defaultFuzzyMaxDistanceRatio = 0.25

    /// State questions ("which lights are on?") name at most this many devices.
    static let stateQueryListMaxKey = "stateQueryListMax"
    static let defaultStateQueryListMax = 5
    static let stateQueryListMaxRange = 1...50

    static func stateQueryListMax(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: stateQueryListMaxKey) as? Int ?? defaultStateQueryListMax
        return min(max(stored, stateQueryListMaxRange.lowerBound), stateQueryListMaxRange.upperBound)
    }

    static func commandVerifyTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: commandVerifyTimeoutKey) as? Double, defaultCommandVerifyTimeout, commandVerifyTimeoutRange)
    }

    static func verifyLevelTolerance(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: verifyLevelToleranceKey) as? Int ?? defaultVerifyLevelTolerance
        return min(max(stored, verifyLevelToleranceRange.lowerBound), verifyLevelToleranceRange.upperBound)
    }

    static func stateFreshness(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: stateFreshnessKey) as? Double, defaultStateFreshness, stateFreshnessRange)
    }

    static func verifySettle(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: verifySettleKey) as? Double, defaultVerifySettle, verifySettleRange)
    }

    static func confirmDeviceCount(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: confirmDeviceCountKey) as? Int ?? defaultConfirmDeviceCount
        return min(max(stored, confirmDeviceCountRange.lowerBound), confirmDeviceCountRange.upperBound)
    }

    static func resolverAmbiguityMargin(from defaults: UserDefaults = .standard) -> Double {
        clamped(defaults.object(forKey: resolverAmbiguityMarginKey) as? Double, defaultResolverAmbiguityMargin, unitFractionRange)
    }

    static func fuzzyMatch(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: fuzzyMatchKey) as? Bool ?? defaultFuzzyMatch
    }

    static func resolverMinCoverage(from defaults: UserDefaults = .standard) -> Double {
        clamped(defaults.object(forKey: resolverMinCoverageKey) as? Double, defaultResolverMinCoverage, unitFractionRange)
    }

    // MARK: Voice

    /// Speech recogniser locale; empty = the system locale.
    static let voiceLocaleKey = "voiceLocaleIdentifier"
    static let speechPreferOnDeviceKey = "speechPreferOnDevice"
    static let defaultSpeechPreferOnDevice = true
    /// Silence after the last partial result that ends an utterance.
    static let speechSilenceTimeoutKey = "speechSilenceTimeoutSeconds"
    static let defaultSpeechSilenceTimeout: TimeInterval = 2.5
    static let speechSilenceTimeoutRange: ClosedRange<TimeInterval> = 0.5...10
    /// Hard cap on one listening session.
    static let speechMaxUtteranceKey = "speechMaxUtteranceSeconds"
    static let defaultSpeechMaxUtterance: TimeInterval = 30
    static let speechMaxUtteranceRange: ClosedRange<TimeInterval> = 3...60
    /// After the audio ends, how long to wait for the recogniser's FINAL (often
    /// corrected) transcript before delivering the latest partial.
    static let speechFinalizeGraceKey = "speechFinalizeGraceSeconds"
    static let defaultSpeechFinalizeGrace: TimeInterval = 1.5
    static let speechFinalizeGraceRange: ClosedRange<TimeInterval> = 0.2...5
    static let spokenRepliesKey = "spokenRepliesEnabled"
    static let defaultSpokenReplies = true

    static func voiceLocale(from defaults: UserDefaults = .standard) -> Locale {
        if let identifier = defaults.string(forKey: voiceLocaleKey), !identifier.isEmpty {
            return Locale(identifier: identifier)
        }
        return Locale.current
    }

    static func speechPreferOnDevice(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: speechPreferOnDeviceKey) as? Bool ?? defaultSpeechPreferOnDevice
    }

    static func speechSilenceTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: speechSilenceTimeoutKey) as? Double, defaultSpeechSilenceTimeout, speechSilenceTimeoutRange)
    }

    static func speechFinalizeGrace(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: speechFinalizeGraceKey) as? Double, defaultSpeechFinalizeGrace, speechFinalizeGraceRange)
    }

    static func speechMaxUtterance(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: speechMaxUtteranceKey) as? Double, defaultSpeechMaxUtterance, speechMaxUtteranceRange)
    }

    static func spokenRepliesEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: spokenRepliesKey) as? Bool ?? defaultSpokenReplies
    }

    // MARK: Output muting while listening

    /// What happens to the speakers while the microphone is open.
    enum ListenOutputMode: String, CaseIterable, Identifiable, Sendable {
        case off, mute, duck
        public var id: String { rawValue }
    }

    static let listenOutputModeKey = "listenOutputMode"
    static let defaultListenOutputMode = ListenOutputMode.mute
    /// Duck level = fraction of the CURRENT output volume kept while listening.
    static let listenDuckLevelKey = "listenDuckLevel"
    static let defaultListenDuckLevel = 0.15
    static let listenDuckLevelRange = 0.0...0.9
    static let listenDuckLevelStep = 0.05
    /// Crash-recovery record (JSON) written when the output is changed and
    /// removed when it is restored.
    static let listenOutputPendingKey = "listenOutputPendingRestore"
    /// Volumes within this distance count as "still the value we set".
    static let outputVolumeTolerance: Float = 0.02

    static func listenOutputMode(from defaults: UserDefaults = .standard) -> ListenOutputMode {
        defaults.string(forKey: listenOutputModeKey).flatMap(ListenOutputMode.init(rawValue:)) ?? defaultListenOutputMode
    }

    static func listenDuckLevel(from defaults: UserDefaults = .standard) -> Double {
        clamped(defaults.object(forKey: listenDuckLevelKey) as? Double, defaultListenDuckLevel, listenDuckLevelRange)
    }

    // MARK: Planner (Apple Foundation Models)

    /// Override for the model instructions; empty = the bundled default.
    static let plannerInstructionsKey = "plannerInstructions"
    /// Upper bound on devices listed in the model's context per request.
    static let plannerMaxDevicesKey = "plannerMaxDevices"
    static let defaultPlannerMaxDevices = 40
    static let plannerMaxDevicesRange = 1...500

    /// Character budget for the device catalogue sent in the prompt (the on-device
    /// model has an 8,192-token window shared with instructions, tool schemas,
    /// tool output and the answer, so the catalogue must stay small).
    static let plannerCatalogueBudgetKey = "plannerCatalogueBudgetChars"
    static let defaultPlannerCatalogueBudget = 2000
    static let plannerCatalogueBudgetRange = 200...12000
    /// Cap on one tool call's output, in characters.
    static let plannerToolOutputBudgetKey = "plannerToolOutputBudgetChars"
    static let defaultPlannerToolOutputBudget = 1200
    static let plannerToolOutputBudgetRange = 200...6000
    /// After a context-overflow the catalogue budget is divided by this for the one retry.
    static let plannerRetryShrinkKey = "plannerRetryShrinkDivisor"
    static let defaultPlannerRetryShrink = 4
    static let plannerRetryShrinkRange = 2...20
    /// Longest the planner may think before the Level-1 result / a message is used.
    static let plannerTimeoutKey = "plannerTimeoutSeconds"
    static let defaultPlannerTimeout: TimeInterval = 20
    static let plannerTimeoutRange: ClosedRange<TimeInterval> = 2...120
    /// Longest one command (execute + verify) may block the command bar.
    static let assistantCommandTimeoutKey = "assistantCommandTimeoutSeconds"
    static let defaultAssistantCommandTimeout: TimeInterval = 15
    static let assistantCommandTimeoutRange: ClosedRange<TimeInterval> = 2...120
    /// Extra wait per additional device in one command: each device is
    /// pre-checked, written and read back in turn (several seconds apiece).
    static let defaultAssistantPerDeviceTimeout: TimeInterval = 8

    static func plannerCatalogueBudget(from defaults: UserDefaults = .standard) -> Int {
        clampedInt(defaults.object(forKey: plannerCatalogueBudgetKey) as? Int, defaultPlannerCatalogueBudget, plannerCatalogueBudgetRange)
    }

    static func plannerToolOutputBudget(from defaults: UserDefaults = .standard) -> Int {
        clampedInt(defaults.object(forKey: plannerToolOutputBudgetKey) as? Int, defaultPlannerToolOutputBudget, plannerToolOutputBudgetRange)
    }

    static func plannerRetryShrink(from defaults: UserDefaults = .standard) -> Int {
        clampedInt(defaults.object(forKey: plannerRetryShrinkKey) as? Int, defaultPlannerRetryShrink, plannerRetryShrinkRange)
    }

    static func plannerTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: plannerTimeoutKey) as? Double, defaultPlannerTimeout, plannerTimeoutRange)
    }

    static func assistantCommandTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: assistantCommandTimeoutKey) as? Double, defaultAssistantCommandTimeout, assistantCommandTimeoutRange)
    }

    private static func clampedInt(_ stored: Int?, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(stored ?? fallback, range.lowerBound), range.upperBound)
    }

    // MARK: Planner provider (Level 2)

    /// Which model plans requests the rule parser cannot understand.
    enum PlannerProvider: String, CaseIterable, Identifiable, Sendable {
        case none, apple, anthropic, openAICompatible
        // Jev is no longer a provider: see AppSettings.jevEnabledKey and
        // migrateLegacyJevProvider (a stored "jev" decodes to nil → migrated).
        public var id: String { rawValue }
        /// Sends device/room names and the command to a remote host.
        public var isCloud: Bool { self == .anthropic || self == .openAICompatible }
    }

    static let plannerProviderKey = "plannerProvider"
    /// Off by default: the rule parser handles direct commands; no model is contacted.
    static let defaultPlannerProvider = PlannerProvider.none

    static let anthropicBaseURLKey = "plannerAnthropicBaseURL"
    static let defaultAnthropicBaseURL = "https://api.anthropic.com"
    static let anthropicMessagesPath = "/v1/messages"
    static let anthropicAPIVersionKey = "plannerAnthropicAPIVersion"
    static let defaultAnthropicAPIVersion = "2023-06-01"
    static let openAIBaseURLKey = "plannerOpenAIBaseURL"
    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"
    static let openAIChatPath = "/chat/completions"
    /// Free-text model name per provider; empty until the user chooses one.
    static let anthropicModelKey = "plannerAnthropicModel"
    static let openAIModelKey = "plannerOpenAIModel"
    static let anthropicModelPlaceholder = "model name, e.g. claude-sonnet-4-5"
    static let openAIModelPlaceholder = "model name, e.g. gpt-4o-mini or a local model"
    /// Cap on the reply length requested from the cloud model (reasoning models spend it on hidden thinking, so the default is generous).
    static let plannerMaxTokensKey = "plannerMaxTokens"
    static let defaultPlannerMaxTokens = 16384
    static let plannerMaxTokensRange = 64...131072
    /// A cloud model has room for far more catalogue than the on-device one
    /// (large context window): these only bound cost and latency.
    static let cloudCatalogueBudgetKey = "plannerCloudCatalogueBudgetChars"
    static let defaultCloudCatalogueBudget = 60000
    static let cloudCatalogueBudgetRange = 500...400000
    /// Devices listed to the cloud planner; the on-device `plannerMaxDevices` stays tight.
    static let cloudMaxDevicesKey = "plannerCloudMaxDevices"
    static let defaultCloudMaxDevices = 500
    static let cloudMaxDevicesRange = 1...2000
    /// Jev's device-choice catalogue keeps its own small budget (not the cloud planner's).
    static let jevCatalogueBudget = 8000
    /// Hosts that may be reached over plain http (local model servers).
    static let plainHTTPHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    static func plannerProvider(from defaults: UserDefaults = .standard) -> PlannerProvider {
        defaults.string(forKey: plannerProviderKey).flatMap(PlannerProvider.init(rawValue:)) ?? defaultPlannerProvider
    }

    static func plannerBaseURL(for provider: PlannerProvider, from defaults: UserDefaults = .standard) -> String {
        let (key, fallback) = provider == .anthropic ? (anthropicBaseURLKey, defaultAnthropicBaseURL) : (openAIBaseURLKey, defaultOpenAIBaseURL)
        let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? fallback : stored
    }

    static func plannerModel(for provider: PlannerProvider, from defaults: UserDefaults = .standard) -> String {
        let key = provider == .anthropic ? anthropicModelKey : openAIModelKey
        return defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func anthropicAPIVersion(from defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: anthropicAPIVersionKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultAnthropicAPIVersion : stored
    }

    static func plannerMaxTokens(from defaults: UserDefaults = .standard) -> Int {
        clampedInt(defaults.object(forKey: plannerMaxTokensKey) as? Int, defaultPlannerMaxTokens, plannerMaxTokensRange)
    }

    static func cloudCatalogueBudget(from defaults: UserDefaults = .standard) -> Int {
        clampedInt(defaults.object(forKey: cloudCatalogueBudgetKey) as? Int, defaultCloudCatalogueBudget, cloudCatalogueBudgetRange)
    }

    static func plannerInstructions(from defaults: UserDefaults = .standard, fallback: String) -> String {
        let stored = defaults.string(forKey: plannerInstructionsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? fallback : stored
    }

    static func cloudMaxDevices(from defaults: UserDefaults = .standard) -> Int {
        clampedInt(defaults.object(forKey: cloudMaxDevicesKey) as? Int, defaultCloudMaxDevices, cloudMaxDevicesRange)
    }

    static func plannerMaxDevices(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: plannerMaxDevicesKey) as? Int ?? defaultPlannerMaxDevices
        return min(max(stored, plannerMaxDevicesRange.lowerBound), plannerMaxDevicesRange.upperBound)
    }

    private static func clamped(_ stored: Double?, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(stored ?? fallback, range.lowerBound), range.upperBound)
    }
}

/// Runtime knobs for DeviceController, snapshotted from AppSettings.
public struct AssistantTimeouts: Equatable, Sendable {
    public var planner: TimeInterval
    public var command: TimeInterval
    /// Added per device beyond the first (`command(forDevices:)`).
    public var perDevice: TimeInterval

    public init(planner: TimeInterval = AppSettings.defaultPlannerTimeout, command: TimeInterval = AppSettings.defaultAssistantCommandTimeout,
                perDevice: TimeInterval = AppSettings.defaultAssistantPerDeviceTimeout) {
        self.planner = planner
        self.command = command
        self.perDevice = perDevice
    }

    /// Deadline for one command over `count` devices: a whole room must not
    /// share a single device's budget.
    public func command(forDevices count: Int) -> TimeInterval {
        command + perDevice * Double(max(count - 1, 0))
    }

    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> AssistantTimeouts {
        AssistantTimeouts(planner: AppSettings.plannerTimeout(from: defaults), command: AppSettings.assistantCommandTimeout(from: defaults))
    }
}

public struct ControlConfig: Equatable, Sendable {
    public var verifyTimeout: TimeInterval
    public var confirmationDeviceThreshold: Int
    /// Read-back tolerance for percent levels.
    public var levelTolerance: Int
    /// Readings older than this are refreshed before a write.
    public var stateFreshness: TimeInterval
    /// Pause between read-back attempts.
    public var settleInterval: TimeInterval

    public init(verifyTimeout: TimeInterval = AppSettings.defaultCommandVerifyTimeout,
                confirmationDeviceThreshold: Int = AppSettings.defaultConfirmDeviceCount,
                levelTolerance: Int = AppSettings.defaultVerifyLevelTolerance,
                stateFreshness: TimeInterval = AppSettings.defaultStateFreshness,
                settleInterval: TimeInterval = AppSettings.defaultVerifySettle) {
        self.verifyTimeout = verifyTimeout
        self.confirmationDeviceThreshold = confirmationDeviceThreshold
        self.levelTolerance = levelTolerance
        self.stateFreshness = stateFreshness
        self.settleInterval = settleInterval
    }

    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> ControlConfig {
        ControlConfig(verifyTimeout: AppSettings.commandVerifyTimeout(from: defaults),
                      confirmationDeviceThreshold: AppSettings.confirmDeviceCount(from: defaults),
                      levelTolerance: AppSettings.verifyLevelTolerance(from: defaults),
                      stateFreshness: AppSettings.stateFreshness(from: defaults),
                      settleInterval: AppSettings.verifySettle(from: defaults))
    }
}

public extension ResolverConfig {
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> ResolverConfig {
        ResolverConfig(ambiguityMargin: AppSettings.resolverAmbiguityMargin(from: defaults),
                       minCoverage: AppSettings.resolverMinCoverage(from: defaults),
                       fuzzy: AppSettings.fuzzyMatch(from: defaults))
    }
}

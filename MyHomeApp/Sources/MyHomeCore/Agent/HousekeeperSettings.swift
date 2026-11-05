// Settings for the housekeeper agent (the Cloud LLM tool-calling loop that
// handles everything the rule parser's fast path does not). Same pattern as
// ControlSettings / JevSettings: named defaults + UserDefaults override keys,
// clamped to a sane range. Nothing in the agent reads a bare literal.
import Foundation

public extension AppSettings {
    // MARK: Housekeeper agent

    /// nil (unset) = on whenever a Cloud LLM provider is configured.
    static let housekeeperEnabledKey = "housekeeperEnabled"
    /// Parsed single-device commands and state questions run without the model.
    static let housekeeperFastPathKey = "housekeeperFastPath"
    static let defaultHousekeeperFastPath = true

    /// Model round trips per turn (each may carry several tool calls).
    static let housekeeperMaxIterationsKey = "housekeeperMaxIterations"
    static let defaultHousekeeperMaxIterations = 8
    static let housekeeperMaxIterationsRange = 1...30
    /// Wall clock for one whole turn (all model calls and device writes).
    static let housekeeperTurnTimeoutKey = "housekeeperTurnTimeoutSeconds"
    static let defaultHousekeeperTurnTimeout: TimeInterval = 180
    static let housekeeperTurnTimeoutRange: ClosedRange<TimeInterval> = 10...900
    /// Bound on one model request (reasoning models think before answering).
    static let housekeeperRequestTimeoutKey = "housekeeperRequestTimeoutSeconds"
    static let defaultHousekeeperRequestTimeout: TimeInterval = 90
    static let housekeeperRequestTimeoutRange: ClosedRange<TimeInterval> = 5...600
    /// Tool calls executed per turn, across iterations.
    static let housekeeperMaxToolCallsKey = "housekeeperMaxToolCalls"
    static let defaultHousekeeperMaxToolCalls = 24
    static let housekeeperMaxToolCallsRange = 1...100
    /// Conversation window: user/assistant turns remembered for follow-ups.
    static let housekeeperMemoryTurnsKey = "housekeeperMemoryTurns"
    static let defaultHousekeeperMemoryTurns = 12
    static let housekeeperMemoryTurnsRange = 0...60
    /// The window is dropped after this much silence.
    static let housekeeperMemoryIdleKey = "housekeeperMemoryIdleSeconds"
    static let defaultHousekeeperMemoryIdle: TimeInterval = 600
    static let housekeeperMemoryIdleRange: ClosedRange<TimeInterval> = 30...7200
    /// Longest the pre-turn refresh of stale device readings may take.
    static let housekeeperFreshenTimeoutKey = "housekeeperFreshenTimeoutSeconds"
    static let defaultHousekeeperFreshenTimeout: TimeInterval = 6
    static let housekeeperFreshenTimeoutRange: ClosedRange<TimeInterval> = 0...60
    /// Cap on one tool result, in characters (list_devices over a big roster).
    static let housekeeperToolOutputBudgetKey = "housekeeperToolOutputBudgetChars"
    static let defaultHousekeeperToolOutputBudget = 12000
    static let housekeeperToolOutputBudgetRange = 500...100000

    /// How tool calls travel: auto = native function calling, falling back
    /// to the text protocol when the provider does not return tool calls.
    enum ToolCallMode: String, CaseIterable, Identifiable, Sendable {
        case auto, native, text
        public var id: String { rawValue }
    }
    static let housekeeperToolModeKey = "housekeeperToolMode"
    static let defaultHousekeeperToolMode = ToolCallMode.auto
    /// What the last probe found ("native" / "text"), and when / for which model.
    static let housekeeperProbedModeKey = "housekeeperProbedToolMode"
    static let housekeeperProbedModelKey = "housekeeperProbedModel"
    static let housekeeperProbedAtKey = "housekeeperProbedAt"
    /// Token budget for the one-tool probe (a reasoning model thinks first).
    static let housekeeperProbeMaxTokens = 2048

    // MARK: Confirmation policy

    /// Kinds whose change always asks first (a socket may power a computer).
    static let housekeeperConfirmKindsKey = "housekeeperConfirmKinds"
    static let defaultHousekeeperConfirmKinds: Set<DeviceKind> = [.plug]
    /// One set may span this many rooms without asking …
    static let housekeeperConfirmMaxRoomsKey = "housekeeperConfirmMaxRooms"
    static let defaultHousekeeperConfirmMaxRooms = 1
    static let housekeeperConfirmMaxRoomsRange = 1...50
    /// … and, when it spans more, touch at most this many devices without asking.
    static let housekeeperConfirmMaxDevicesKey = "housekeeperConfirmMaxDevices"
    static let defaultHousekeeperConfirmMaxDevices = 8
    static let housekeeperConfirmMaxDevicesRange = 1...500

    // MARK: Memory files (Application Support/MyHome)

    static let householdNotesFileName = "household-notes.json"
    static let lastReplyFileName = "last-reply.json"
    static let householdNotesMaxCount = 200
    static let householdNoteMaxLength = 500

    // MARK: Diagnostics

    /// `myhome://say?text=…` and `--say` run the text through the assistant
    /// (origin .url / .diagnostic). Any local process can open the scheme, so
    /// both are OFF unless enabled in Settings or the process is launched with
    /// `MYHOME_DIAGNOSTICS=1` (live verification). Neither can confirm ("yes").
    static let assistantSayURLEnabledKey = "assistantSayURLEnabled"
    static let defaultAssistantSayURLEnabled = false
    static let diagnosticsEnvironmentVariable = "MYHOME_DIAGNOSTICS"
    static let diagnosticsEnvironmentEnabledValue = "1"
    static let sayURLScheme = "myhome"
    static let sayURLHost = "say"
    static let sayURLTextParameter = "text"
    static let sayLaunchArgument = "--say"
    static let probeLaunchArgument = "--probe-tools"
    /// Delay before a `--say` launch argument runs (bridge + first status sweep).
    static let sayLaunchDelayKey = "assistantSayLaunchDelaySeconds"
    static let defaultSayLaunchDelay: TimeInterval = 12
    static let sayLaunchDelayRange: ClosedRange<TimeInterval> = 0...120

    // MARK: Readers

    static func housekeeperEnabled(from defaults: UserDefaults = .standard) -> Bool {
        if let stored = defaults.object(forKey: housekeeperEnabledKey) as? Bool { return stored }
        return plannerProvider(from: defaults).isCloud
    }

    static func housekeeperFastPath(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: housekeeperFastPathKey) as? Bool ?? defaultHousekeeperFastPath
    }

    static func housekeeperMaxIterations(from defaults: UserDefaults = .standard) -> Int {
        clampedRange(defaults.object(forKey: housekeeperMaxIterationsKey) as? Int, defaultHousekeeperMaxIterations, housekeeperMaxIterationsRange)
    }

    static func housekeeperTurnTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        clampedSeconds(defaults.object(forKey: housekeeperTurnTimeoutKey) as? Double, defaultHousekeeperTurnTimeout, housekeeperTurnTimeoutRange)
    }

    static func housekeeperRequestTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        clampedSeconds(defaults.object(forKey: housekeeperRequestTimeoutKey) as? Double, defaultHousekeeperRequestTimeout, housekeeperRequestTimeoutRange)
    }

    static func housekeeperMaxToolCalls(from defaults: UserDefaults = .standard) -> Int {
        clampedRange(defaults.object(forKey: housekeeperMaxToolCallsKey) as? Int, defaultHousekeeperMaxToolCalls, housekeeperMaxToolCallsRange)
    }

    static func housekeeperMemoryTurns(from defaults: UserDefaults = .standard) -> Int {
        clampedRange(defaults.object(forKey: housekeeperMemoryTurnsKey) as? Int, defaultHousekeeperMemoryTurns, housekeeperMemoryTurnsRange)
    }

    static func housekeeperMemoryIdle(from defaults: UserDefaults = .standard) -> TimeInterval {
        clampedSeconds(defaults.object(forKey: housekeeperMemoryIdleKey) as? Double, defaultHousekeeperMemoryIdle, housekeeperMemoryIdleRange)
    }

    static func housekeeperFreshenTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        clampedSeconds(defaults.object(forKey: housekeeperFreshenTimeoutKey) as? Double, defaultHousekeeperFreshenTimeout, housekeeperFreshenTimeoutRange)
    }

    static func housekeeperToolOutputBudget(from defaults: UserDefaults = .standard) -> Int {
        clampedRange(defaults.object(forKey: housekeeperToolOutputBudgetKey) as? Int, defaultHousekeeperToolOutputBudget, housekeeperToolOutputBudgetRange)
    }

    static func housekeeperToolMode(from defaults: UserDefaults = .standard) -> ToolCallMode {
        defaults.string(forKey: housekeeperToolModeKey).flatMap(ToolCallMode.init(rawValue:)) ?? defaultHousekeeperToolMode
    }

    /// Comma-separated DeviceKind raw values; unknown words are ignored.
    static func housekeeperConfirmKinds(from defaults: UserDefaults = .standard) -> Set<DeviceKind> {
        guard let stored = defaults.string(forKey: housekeeperConfirmKindsKey) else { return defaultHousekeeperConfirmKinds }
        let kinds = stored.split(separator: ",").compactMap { DeviceKind(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
        return Set(kinds)
    }

    static func housekeeperConfirmMaxRooms(from defaults: UserDefaults = .standard) -> Int {
        clampedRange(defaults.object(forKey: housekeeperConfirmMaxRoomsKey) as? Int, defaultHousekeeperConfirmMaxRooms, housekeeperConfirmMaxRoomsRange)
    }

    static func housekeeperConfirmMaxDevices(from defaults: UserDefaults = .standard) -> Int {
        clampedRange(defaults.object(forKey: housekeeperConfirmMaxDevicesKey) as? Int, defaultHousekeeperConfirmMaxDevices, housekeeperConfirmMaxDevicesRange)
    }

    static func assistantSayURLEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: assistantSayURLEnabledKey) as? Bool ?? defaultAssistantSayURLEnabled
    }

    /// The one gate for BOTH diagnostic say paths (URL and `--say`): the
    /// Settings toggle, or the diagnostics environment variable.
    static func diagnosticSayAllowed(defaults: UserDefaults = .standard,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        assistantSayURLEnabled(from: defaults)
            || environment[diagnosticsEnvironmentVariable] == diagnosticsEnvironmentEnabledValue
    }

    static func sayLaunchDelay(from defaults: UserDefaults = .standard) -> TimeInterval {
        clampedSeconds(defaults.object(forKey: sayLaunchDelayKey) as? Double, defaultSayLaunchDelay, sayLaunchDelayRange)
    }

    /// The recorded probe outcome, for the Test connection text (nil = never probed).
    static func housekeeperProbeSummary(from defaults: UserDefaults = .standard) -> String? {
        guard let mode = defaults.string(forKey: housekeeperProbedModeKey), !mode.isEmpty else { return nil }
        var details: [String] = []
        if let model = defaults.string(forKey: housekeeperProbedModelKey), !model.isEmpty { details.append(model) }
        if let at = defaults.object(forKey: housekeeperProbedAtKey) as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            details.append("probed \(formatter.string(from: at))")
        }
        return "Tool calls: \(mode)" + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
    }

    static func recordHousekeeperProbe(mode: String, model: String, at date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(mode, forKey: housekeeperProbedModeKey)
        defaults.set(model, forKey: housekeeperProbedModelKey)
        defaults.set(date, forKey: housekeeperProbedAtKey)
    }

    private static func clampedRange(_ stored: Int?, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(stored ?? fallback, range.lowerBound), range.upperBound)
    }

    private static func clampedSeconds(_ stored: Double?, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
        guard let stored, stored.isFinite else { return fallback }
        return min(max(stored, range.lowerBound), range.upperBound)
    }
}

/// Runtime knobs for one HousekeeperAgent, snapshotted from AppSettings.
public struct HousekeeperLimits: Equatable, Sendable {
    public var maxIterations: Int
    public var turnTimeout: TimeInterval
    public var requestTimeout: TimeInterval
    public var maxToolCalls: Int
    public var memoryTurns: Int
    public var memoryIdle: TimeInterval
    public var toolOutputBudget: Int
    public var freshenTimeout: TimeInterval

    public init(maxIterations: Int = AppSettings.defaultHousekeeperMaxIterations,
                turnTimeout: TimeInterval = AppSettings.defaultHousekeeperTurnTimeout,
                requestTimeout: TimeInterval = AppSettings.defaultHousekeeperRequestTimeout,
                maxToolCalls: Int = AppSettings.defaultHousekeeperMaxToolCalls,
                memoryTurns: Int = AppSettings.defaultHousekeeperMemoryTurns,
                memoryIdle: TimeInterval = AppSettings.defaultHousekeeperMemoryIdle,
                toolOutputBudget: Int = AppSettings.defaultHousekeeperToolOutputBudget,
                freshenTimeout: TimeInterval = AppSettings.defaultHousekeeperFreshenTimeout) {
        self.maxIterations = maxIterations
        self.turnTimeout = turnTimeout
        self.requestTimeout = requestTimeout
        self.maxToolCalls = maxToolCalls
        self.memoryTurns = memoryTurns
        self.memoryIdle = memoryIdle
        self.toolOutputBudget = toolOutputBudget
        self.freshenTimeout = freshenTimeout
    }

    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> HousekeeperLimits {
        HousekeeperLimits(maxIterations: AppSettings.housekeeperMaxIterations(from: defaults),
                          turnTimeout: AppSettings.housekeeperTurnTimeout(from: defaults),
                          requestTimeout: AppSettings.housekeeperRequestTimeout(from: defaults),
                          maxToolCalls: AppSettings.housekeeperMaxToolCalls(from: defaults),
                          memoryTurns: AppSettings.housekeeperMemoryTurns(from: defaults),
                          memoryIdle: AppSettings.housekeeperMemoryIdle(from: defaults),
                          toolOutputBudget: AppSettings.housekeeperToolOutputBudget(from: defaults),
                          freshenTimeout: AppSettings.housekeeperFreshenTimeout(from: defaults))
    }
}

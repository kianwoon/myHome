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

    static let resolverAmbiguityMarginKey = "resolverAmbiguityMargin"
    static let defaultResolverAmbiguityMargin = 0.1
    static let resolverMinCoverageKey = "resolverMinCoverage"
    static let defaultResolverMinCoverage = 0.5
    static let unitFractionRange = 0.0...1.0

    static func commandVerifyTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: commandVerifyTimeoutKey) as? Double, defaultCommandVerifyTimeout, commandVerifyTimeoutRange)
    }

    static func confirmDeviceCount(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: confirmDeviceCountKey) as? Int ?? defaultConfirmDeviceCount
        return min(max(stored, confirmDeviceCountRange.lowerBound), confirmDeviceCountRange.upperBound)
    }

    static func resolverAmbiguityMargin(from defaults: UserDefaults = .standard) -> Double {
        clamped(defaults.object(forKey: resolverAmbiguityMarginKey) as? Double, defaultResolverAmbiguityMargin, unitFractionRange)
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
    static let defaultSpeechSilenceTimeout: TimeInterval = 1.5
    static let speechSilenceTimeoutRange: ClosedRange<TimeInterval> = 0.5...10
    /// Hard cap on one listening session.
    static let speechMaxUtteranceKey = "speechMaxUtteranceSeconds"
    static let defaultSpeechMaxUtterance: TimeInterval = 15
    static let speechMaxUtteranceRange: ClosedRange<TimeInterval> = 3...60
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

    static func speechMaxUtterance(from defaults: UserDefaults = .standard) -> TimeInterval {
        clamped(defaults.object(forKey: speechMaxUtteranceKey) as? Double, defaultSpeechMaxUtterance, speechMaxUtteranceRange)
    }

    static func spokenRepliesEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: spokenRepliesKey) as? Bool ?? defaultSpokenReplies
    }

    // MARK: Planner (Apple Foundation Models)

    static let plannerEnabledKey = "plannerEnabled"
    static let defaultPlannerEnabled = true
    /// Override for the model instructions; empty = the bundled default.
    static let plannerInstructionsKey = "plannerInstructions"
    /// Upper bound on devices listed in the model's context per request.
    static let plannerMaxDevicesKey = "plannerMaxDevices"
    static let defaultPlannerMaxDevices = 60
    static let plannerMaxDevicesRange = 1...500

    static func plannerEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: plannerEnabledKey) as? Bool ?? defaultPlannerEnabled
    }

    static func plannerInstructions(from defaults: UserDefaults = .standard, fallback: String) -> String {
        let stored = defaults.string(forKey: plannerInstructionsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? fallback : stored
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
public struct ControlConfig: Equatable, Sendable {
    public var verifyTimeout: TimeInterval
    public var confirmationDeviceThreshold: Int

    public init(verifyTimeout: TimeInterval = AppSettings.defaultCommandVerifyTimeout,
                confirmationDeviceThreshold: Int = AppSettings.defaultConfirmDeviceCount) {
        self.verifyTimeout = verifyTimeout
        self.confirmationDeviceThreshold = confirmationDeviceThreshold
    }

    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> ControlConfig {
        ControlConfig(verifyTimeout: AppSettings.commandVerifyTimeout(from: defaults),
                      confirmationDeviceThreshold: AppSettings.confirmDeviceCount(from: defaults))
    }
}

public extension ResolverConfig {
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> ResolverConfig {
        ResolverConfig(ambiguityMargin: AppSettings.resolverAmbiguityMargin(from: defaults),
                       minCoverage: AppSettings.resolverMinCoverage(from: defaults))
    }
}

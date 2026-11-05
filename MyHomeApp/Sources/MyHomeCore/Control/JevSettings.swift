// Settings for the Jev decider (a choice classifier on the OpenRouter
// decisions endpoint). Same pattern as ControlSettings: named defaults +
// UserDefaults override keys, clamped to a sane range. Every jev literal
// (endpoint, gate, timeout, retry, wire bounds) lives here.
import Foundation

public extension AppSettings {
    // MARK: Jev decider

    // allow-hardcode: the decisions endpoint default (jev.md §2; overridable in Settings → AI Models).
    static let defaultJevEndpoint = "https://openrouter.ai/api/alpha/decisions"
    static let jevEndpointKey = "jevEndpoint"
    /// Free-text wire model id; empty until the user chooses one.
    static let jevModelKey = "jevModel"
    // allow-hardcode: placeholder text only, never sent.
    static let jevModelPlaceholder = "decider model id, e.g. perplexity/pplx-decider-flash-v1.2"
    /// A pasted transport spec ("openrouter/<id>") has this prefix stripped:
    /// the endpoint is explicit, so only the model id goes on the wire.
    static let jevTransportPrefix = "openrouter/"

    // allow-hardcode: the OpenRouter host; a 401/403 from it triggers the one key-info follow-up.
    static let openRouterHost = "openrouter.ai"
    // allow-hardcode: OpenRouter's key-info endpoint (same host as the decisions endpoint; https only).
    static let jevKeyInfoURL = "https://openrouter.ai/api/v1/key"

    /// Accept a choice only when probabilities[choice] reaches this.
    static let jevThresholdKey = "jevThreshold"
    static let defaultJevThreshold = 0.7
    /// The confidence floor: a row below it is never trusted, whatever the threshold.
    static let jevConfidenceFloor = 0.3
    static let jevThresholdRange: ClosedRange<Double> = jevConfidenceFloor...1.0
    static let jevThresholdStep = 0.05

    /// Per-attempt bound on one decisions POST.
    static let jevTimeoutKey = "jevTimeoutSeconds"
    static let defaultJevTimeout: TimeInterval = 3
    static let jevTimeoutRange: ClosedRange<TimeInterval> = 1...30

    /// Retry only transient failures (network/timeout, 429, 5xx): 3 attempts, then fail open.
    static let jevMaxAttempts = 3
    /// Longest server error text quoted back in a 401/403 diagnostic.
    static let jevServerMessageMax = 120
    static let jevRetryBackoffs: [TimeInterval] = [0.2, 0.6]

    /// Contract bounds on a choice question's options and labels.
    static let jevChoiceOptionsRange = 2...255
    static let jevChoiceLabelMax = 64
    /// Most candidates named back to the user after a below-gate answer.
    static let jevSuggestionCount = 3

    /// Keychain account for the decisions key, and the env fallback (like opencode).
    static let jevSecretAccount = "jev-openrouter"
    static let jevKeyEnvironmentVariable = "OPENROUTER_API_KEY"
    // allow-hardcode: OpenRouter attribution header value.
    static let jevAppTitle = "MyHome"
    // allow-hardcode: OpenRouter attribution referer (opencode sends https://opencode.ai/).
    static let jevReferer = "https://myhome.app/"

    /// Jev router & matcher on/off — independent of the Cloud LLM provider, so
    /// both can be active together (parser → Jev → Cloud LLM).
    static let jevEnabledKey = "jevEnabled"
    static let defaultJevEnabled = false
    /// The pre-split `plannerProvider` value that selected Jev (migrated once).
    static let legacyJevProviderRawValue = "jev"

    static func jevEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: jevEnabledKey) as? Bool ?? defaultJevEnabled
    }

    /// One-time, idempotent: a stored provider "jev" becomes jevEnabled=true
    /// with provider none. Reads the RAW string (the enum no longer has jev).
    @discardableResult
    static func migrateLegacyJevProvider(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: plannerProviderKey) == legacyJevProviderRawValue else { return false }
        defaults.set(true, forKey: jevEnabledKey)
        defaults.set(PlannerProvider.none.rawValue, forKey: plannerProviderKey)
        return true
    }

    static func jevEndpoint(from defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: jevEndpointKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultJevEndpoint : stored
    }

    /// The wire model id (a leading transport prefix is stripped).
    static func jevModel(from defaults: UserDefaults = .standard) -> String {
        jevWireModel(defaults.string(forKey: jevModelKey) ?? "")
    }

    static func jevWireModel(_ spec: String) -> String {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(jevTransportPrefix) else { return trimmed }
        return String(trimmed.dropFirst(jevTransportPrefix.count))
    }

    /// Never below the confidence floor, never above 1.
    static func jevThreshold(from defaults: UserDefaults = .standard) -> Double {
        clampedJevThreshold(defaults.object(forKey: jevThresholdKey) as? Double ?? defaultJevThreshold)
    }

    static func clampedJevThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return defaultJevThreshold }
        return min(max(value, jevThresholdRange.lowerBound), jevThresholdRange.upperBound)
    }

    static func jevTimeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.object(forKey: jevTimeoutKey) as? Double ?? defaultJevTimeout
        guard stored.isFinite else { return defaultJevTimeout }
        return min(max(stored, jevTimeoutRange.lowerBound), jevTimeoutRange.upperBound)
    }
}

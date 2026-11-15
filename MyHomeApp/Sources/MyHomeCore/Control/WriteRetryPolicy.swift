// baseline-guard:allow new source file, no prior baseline
// When a device write may be repeated. General rule: ONLY an unknown outcome
// (timeout, no reply, a dropped connection) of an IDEMPOTENT command is
// retried — sending "power off" or "level 40%" twice leaves the device in the
// same state as once. A definite rejection, a policy denial, or a command
// whose repetition changes the result (start a stream, resume playback) is
// never repeated. Before each retry the device is read back; when it already
// shows the commanded value nothing is re-sent.
import Foundation

public struct WriteRetryPolicy: Equatable, Sendable {
    /// Extra writes allowed after the first (0 = never retry).
    public var maxRetries: Int
    /// Pause before retry n is `backoff * n`.
    public var backoff: TimeInterval
    /// A retry starts only when this much of the device's budget remains.
    public var minRemaining: TimeInterval

    public init(maxRetries: Int = AppSettings.defaultControlRetryMax,
                backoff: TimeInterval = AppSettings.defaultControlRetryBackoff,
                minRemaining: TimeInterval = AppSettings.defaultControlRetryMinRemaining) {
        self.maxRetries = max(maxRetries, 0)
        self.backoff = max(backoff, 0)
        self.minRemaining = max(minRemaining, 0)
    }

    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> WriteRetryPolicy {
        WriteRetryPolicy(maxRetries: AppSettings.controlRetryMax(from: defaults),
                         backoff: AppSettings.controlRetryBackoff(from: defaults))
    }

    /// Pause before the given retry (1-based).
    public func delay(beforeRetry number: Int) -> TimeInterval {
        backoff * Double(max(number, 1))
    }

    /// True for commands whose repetition is harmless (absolute targets).
    /// Exhaustive on purpose: a new command must decide explicitly.
    public static func isIdempotent(_ command: DeviceCommand) -> Bool {
        switch command {
        case .power, .level, .color, .colorTemperature, .mode, .fanSpeed, .cover, .volume, .mute, .input:
            return true
        case .play, .playback:
            // Starting a stream twice restarts or re-queues it; "resume" after
            // an unknown outcome could fight a pause made in between.
            return false
        }
    }

    /// Whether another write may be attempted after `attempts` writes.
    public func allowsRetry(_ command: DeviceCommand, attempts: Int, remaining: TimeInterval) -> Bool {
        Self.isIdempotent(command) && attempts <= maxRetries && remaining >= minRemaining
    }
}

/// The outcome of one write attempt, with whether it was ambiguous.
struct WriteAttempt: Equatable, Sendable {
    var status: OutcomeStatus
    /// The transport failed in a way that does not say whether the device
    /// applied the write (timeout, connection error, no reply). Only these
    /// attempts are candidates for a retry; a bridge "ok" or a definite
    /// rejection never are.
    var ambiguous: Bool

    static func definite(_ status: OutcomeStatus) -> WriteAttempt {
        WriteAttempt(status: status, ambiguous: false)
    }
}

/// Ambiguous-vs-definite classification of transport failures, per transport.
enum WriteFailureClass {
    static func isAmbiguous(_ error: KEFError) -> Bool {
        switch error {
        case .timeout, .unreachable, .malformedResponse:
            return true
        case .invalidAddress, .unsupportedModel, .unsupportedInput, .authenticationRequired, .rejected,
             .standbyBlocksWrite, .volumeOutOfRange:
            return false
        }
    }

    static func isAmbiguous(_ error: CastError) -> Bool {
        switch error {
        case .unreachable, .timeout, .malformedResponse:
            return true
        case .invalidAddress, .noActiveSession, .unplayableSource, .searchFailed, .youtubeRefused, .volumeOutOfRange:
            return false
        }
    }

    /// Transport failures the store's classifier (which also drives its paint
    /// revert) reads as definite, but which say nothing about whether the
    /// device acted — or prove it never got the write: tinytuya 901/905, the
    /// app-side bridge timeout, and the bridge's Briturn TCP send failures.
    // allow-hardcode: classification of known transport error texts.
    static let transportPhrases = [
        "901", "905", "unable to connect", "did not reply", "power command failed", "color command failed"
    ]

    /// Briturn and the Tuya bridge only report text: transport-class words
    /// (the store's list plus `transportPhrases`) → ambiguous.
    static func isAmbiguous(message: String) -> Bool {
        let text = message.lowercased()
        return !DeviceStore.isDefiniteRejection(message) || transportPhrases.contains { text.contains($0) }
    }
}

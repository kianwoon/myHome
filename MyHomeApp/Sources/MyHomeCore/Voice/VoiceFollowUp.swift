// When a voice reply ends in a question ("Which fan?", "… Go ahead?") the
// user answers out loud, so the mic reopens hands-free once the question has
// been spoken. Capped per session so background noise answered by another
// question can never keep the mic (and a paid model) going in a loop.
import Foundation

public extension AppSettings {
    /// Reopen the mic after a spoken question; off = press / wake again to answer.
    static let voiceFollowUpEnabledKey = "voiceFollowUpEnabled"
    static let defaultVoiceFollowUpEnabled = true
    /// Questions in a row that may reopen the mic before the session ends.
    static let voiceFollowUpMaxTurnsKey = "voiceFollowUpMaxTurns"
    static let defaultVoiceFollowUpMaxTurns = 3
    static let voiceFollowUpMaxTurnsRange: ClosedRange<Int> = 1...10
    /// Pause after the spoken question before the mic opens, so the room's
    /// echo of the reply is not transcribed as the answer.
    static let voiceFollowUpDelayKey = "voiceFollowUpDelaySeconds"
    static let defaultVoiceFollowUpDelay: Double = 0.4
    static let voiceFollowUpDelayRange: ClosedRange<Double> = 0...3

    static func voiceFollowUpEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: voiceFollowUpEnabledKey) == nil ? defaultVoiceFollowUpEnabled : defaults.bool(forKey: voiceFollowUpEnabledKey)
    }

    static func voiceFollowUpMaxTurns(from defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: voiceFollowUpMaxTurnsKey) != nil else { return defaultVoiceFollowUpMaxTurns }
        return min(max(defaults.integer(forKey: voiceFollowUpMaxTurnsKey), voiceFollowUpMaxTurnsRange.lowerBound),
                   voiceFollowUpMaxTurnsRange.upperBound)
    }

    static func voiceFollowUpDelay(from defaults: UserDefaults = .standard) -> TimeInterval {
        speechClamp(defaults, voiceFollowUpDelayKey, defaultVoiceFollowUpDelay, voiceFollowUpDelayRange)
    }
}

public enum VoiceFollowUp {
    /// Reply kinds that end in a question the user answers by voice.
    public static func asksForAnswer(_ kind: AssistantReply.Kind) -> Bool {
        kind == .ambiguous || kind == .needsConfirmation
    }

    /// Reopen the mic after this reply? `turnsSoFar` counts follow-ups
    /// already opened in this voice session.
    public static func shouldListen(after kind: AssistantReply.Kind, enabled: Bool, turnsSoFar: Int, maxTurns: Int) -> Bool {
        enabled && asksForAnswer(kind) && turnsSoFar < maxTurns
    }
}

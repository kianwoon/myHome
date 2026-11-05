// Pure text helpers for AssistantCoordinator (no state): the spoken
// "couldn't match" / "I heard" phrasings, intent names for logs, and planner
// error messages. Kept out of the coordinator so its flow stays readable.
import Foundation

extension AssistantCoordinator {
    /// The "couldn't match" reply always shows the text it was given, so a
    /// recogniser artefact is visible instead of a bare "didn't understand".
    static func notUnderstoodText(_ utterance: String, origin: CommandOrigin, note: String) -> String {
        let shown = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if TextNormalizer.rawTokens(shown).isEmpty { return nothingHeardText }
        let lead = (origin == .voice || origin == .siri) ? "I heard" : "I read"
        return "\(lead) \u{201C}\(shown)\u{201D} but couldn't match it to a command\(note)."
    }

    static func heardText(_ utterance: String, origin: CommandOrigin) -> String {
        let lead = (origin == .voice || origin == .siri) ? "I heard" : "I read"
        return "\(lead) \u{201C}\(utterance.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}"
    }

    // allow-hardcode: spoken UI copy (points at the Settings tab by name).
    /// Jev judged the request an inference ("the room is stuffy") but no
    /// Cloud LLM can plan it. Nothing runs.
    static func inferenceNeedsPlannerText(_ utterance: String, origin: CommandOrigin, reason: String?) -> String {
        let why = reason.map { " (the Cloud LLM is unavailable: \($0))" } ?? ""
        return "\(heardText(utterance, origin: origin)). That describes a situation rather than a command; working out what to do needs a Cloud LLM\(why). Set one up in Settings → AI Models, or say the command directly."
    }

    /// Words that only point back at the question ("the desk ONE"), not at a device.
    static let answerFillerWords: Set<String> = ["one", "ones"]

    static func answerText(_ utterance: String) -> String {
        let kept = TextNormalizer.rawTokens(utterance).filter { !answerFillerWords.contains($0) }
        return kept.isEmpty ? utterance : kept.joined(separator: " ")
    }

    static func intentName(_ intent: ParsedIntent) -> String {
        switch intent {
        case .command: return "command"
        case .status: return "status"
        case .stateQuery: return "stateQuery"
        case .confirm: return "confirm"
        case .cancel: return "cancel"
        case .unknown: return "unknown"
        }
    }

    static func message(for error: Error) -> String {
        if case PlannerError.unavailable(let text) = error { return text }
        if case PlannerError.failed(let text) = error { return text }
        return error.localizedDescription
    }
}

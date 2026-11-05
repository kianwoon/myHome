// Model output → ProposedPlan, shared by every planner (Apple on-device and
// cloud). Unknown actions are dropped into a clarification rather than guessed;
// identical commands on several devices collapse into one step so the
// confirmation reads naturally. The model only proposes.
import Foundation

/// Provider-neutral plan as the model writes it (handles, not device ids).
struct PlanPayload: Decodable, Equatable {
    struct Action: Decodable, Equatable {
        var device: String
        var action: String
        var value: Int?
        var mode: String?
        var color: String?
    }

    var actions: [Action]
    var summary: String
    var clarification: String

    private enum CodingKeys: String, CodingKey { case actions, summary, clarification }

    init(actions: [Action], summary: String, clarification: String) {
        self.actions = actions
        self.summary = summary
        self.clarification = clarification
    }

    // Models drop empty fields; every field is optional on the wire.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        clarification = try container.decodeIfPresent(String.self, forKey: .clarification) ?? ""
    }
}

enum PlanConverter {
    /// Action names the planners may use; also the schema shown to cloud models.
    static let actionNames = ["turnOn", "turnOff", "setLevel", "setFanSpeed", "setColorTemperature", "setColor", "setMode", "open", "close", "stop"]

    static func convert(_ payload: PlanPayload, resolveDevice: (String) -> String = { $0 }) -> ProposedPlan {
        var steps: [ProposedStep] = []
        var problems: [String] = []
        for action in payload.actions {
            guard let command = command(for: action, problems: &problems) else { continue }
            let id = resolveDevice(action.device)
            if let index = steps.firstIndex(where: { $0.command == command }) {
                if !steps[index].deviceIDs.contains(id) { steps[index].deviceIDs.append(id) }
            } else {
                steps.append(ProposedStep(deviceIDs: [id], command: command))
            }
        }
        let question = payload.clarification.trimmingCharacters(in: .whitespacesAndNewlines)
        var clarification = question.isEmpty ? nil : question
        if steps.isEmpty, clarification == nil, !problems.isEmpty { clarification = problems.joined(separator: " ") }
        return ProposedPlan(steps: steps, summary: payload.summary.trimmingCharacters(in: .whitespacesAndNewlines), clarification: clarification)
    }

    private static func command(for action: PlanPayload.Action, problems: inout [String]) -> DeviceCommand? {
        switch action.action {
        case "turnOn": return .power(true)
        case "turnOff": return .power(false)
        case "open": return .cover(.open)
        case "close": return .cover(.close)
        case "stop": return .cover(.stop)
        case "setLevel":
            guard let value = action.value else { problems.append("No level was given."); return nil }
            return .level(Percent.clamp(value))
        case "setColorTemperature":
            guard let value = action.value else { problems.append("No colour temperature was given."); return nil }
            return .colorTemperature(Percent.clamp(value))
        case "setFanSpeed":
            guard let value = action.value else { problems.append("No fan speed was given."); return nil }
            return .fanSpeed(value)
        case "setMode":
            guard let mode = action.mode, !mode.isEmpty else { problems.append("No mode was given."); return nil }
            return .mode(mode)
        case "setColor":
            let grammar = CommandGrammar.standard
            let name = TextNormalizer.fold(action.color ?? "").trimmingCharacters(in: .whitespaces)
            if let percent = grammar.temperaturePhrases[name] { return .colorTemperature(percent) }
            if let rgb = grammar.colorNames[name] { return .color(rgb) }
            problems.append("I don't know the colour \"\(action.color ?? "")\".")
            return nil
        default:
            problems.append("I don't know the action \"\(action.action)\".")
            return nil
        }
    }
}

// Level-2 planner on Apple Foundation Models (on-device, macOS 26+).
//
// General rule: THE MODEL ONLY PROPOSES. It sees the device registry (ids,
// names, rooms, capabilities, state) through tools and a structured
// @Generable plan; every step still goes through DeviceController's policy,
// and the coordinator asks the user before running a model-authored plan.
// Availability is triple-gated: the framework must be importable, the OS
// must be macOS 26+, and SystemLanguageModel must report `.available`.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum PlannerFactory {
    /// The on-device planner when the platform has one, else nil (Level 1 only).
    @MainActor
    public static func makePlanner(controller: DeviceController, defaults: UserDefaults = .standard) -> NaturalLanguagePlanner? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return FoundationModelsPlanner(controller: controller, defaults: defaults)
        }
        #endif
        return nil
    }

    /// Why Level 2 is off on this Mac, for the UI; nil when a planner exists.
    @MainActor
    public static func platformNote() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return nil }
        #endif
        return "Natural-language planning needs macOS 26 or newer."
    }
}

/// Registry rendering shared by the prompt and the tools (plain text, one
/// device per line, ids first so the model copies them verbatim).
enum PlannerRegistry {
    static func render(_ devices: [DeviceSummary]) -> String {
        devices.map { device in
            var parts = ["id=\(device.id)", "name=\"\(device.name)\"", "kind=\(device.kind.rawValue)"]
            if !device.room.isEmpty { parts.append("room=\"\(device.room)\"") }
            if let group = device.group, !group.isEmpty { parts.append("group=\"\(group)\"") }
            parts.append("can=\(device.capabilities.map(\.rawValue).joined(separator: ","))")
            if let on = device.isOn { parts.append("power=\(on ? "on" : "off")") }
            if let level = device.levelPercent { parts.append("level=\(level)%") }
            parts.append("reach=\(device.reachability.rawValue)")
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)

@available(macOS 26, *)
@Generable(description: "The kind of action to perform on a device")
enum PlannedActionKind: String {
    case turnOn, turnOff, setLevel, setFanSpeed, setColorTemperature, setColor, setMode, open, close, stop
}

@available(macOS 26, *)
@Generable(description: "One action on one device")
struct PlannedAction {
    @Guide(description: "The exact id of the device, copied from the device list")
    var deviceID: String
    @Guide(description: "What to do")
    var action: PlannedActionKind
    @Guide(description: "Percent 0-100 for setLevel and setColorTemperature (0 warm, 100 cool); the gear number for setFanSpeed")
    var value: Int?
    @Guide(description: "Mode name for setMode, exactly as the device lists it")
    var mode: String?
    @Guide(description: "Colour name for setColor, e.g. red or warm white")
    var color: String?
}

@available(macOS 26, *)
@Generable(description: "A plan of device actions for a home-control request")
struct PlannedResponse {
    @Guide(description: "Actions to run, in order; empty when the request is unclear or no device fits")
    var actions: [PlannedAction]
    @Guide(description: "One short sentence describing the plan")
    var summary: String
    @Guide(description: "A question for the user when the request is ambiguous or impossible; empty otherwise")
    var clarification: String
}

@available(macOS 26, *)
struct ListDevicesTool: Tool {
    let name = "listDevices"
    let description = "Lists every controllable device with its id, name, room, kind, capabilities and current state."
    let provider: @Sendable () async -> [DeviceSummary]

    @Generable
    struct Arguments {
        @Guide(description: "Optional word to filter by room, group or kind; empty for all")
        var filter: String
    }

    func call(arguments: Arguments) async throws -> String {
        let all = await provider()
        let needle = TextNormalizer.fold(arguments.filter).trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? all : all.filter { device in
            TextNormalizer.fold(device.room).contains(needle) || TextNormalizer.fold(device.group ?? "").contains(needle)
                || device.kind.rawValue.contains(needle) || TextNormalizer.fold(device.name).contains(needle)
        }
        return shown.isEmpty ? "No devices match." : PlannerRegistry.render(shown)
    }
}

@available(macOS 26, *)
struct FindDevicesTool: Tool {
    let name = "findDevices"
    let description = "Finds the devices a phrase like 'bedroom lights' or 'study fan' refers to; returns candidates with ids, or says the phrase is ambiguous."
    let finder: @Sendable (String) async -> (devices: [DeviceSummary], ambiguous: Bool)

    @Generable
    struct Arguments {
        @Guide(description: "The device phrase from the user's request")
        var phrase: String
    }

    func call(arguments: Arguments) async throws -> String {
        let found = await finder(arguments.phrase)
        if found.devices.isEmpty { return "No device matches \"\(arguments.phrase)\"." }
        let prefix = found.ambiguous ? "Ambiguous — ask the user which one:\n" : ""
        return prefix + PlannerRegistry.render(found.devices)
    }
}

@available(macOS 26, *)
@MainActor
public final class FoundationModelsPlanner: NaturalLanguagePlanner {
    // allow-hardcode: these are the model instructions (a prompt), reviewed
    // guidance that AppSettings.plannerInstructions can override at runtime.
    public static let defaultInstructions = """
    You turn a spoken or typed home-control request into a plan of device actions.
    Use only device ids that appear in the device list or in tool results; never invent a device.
    Use the findDevices tool when a phrase could mean several devices, and the listDevices tool to see what exists.
    If the request is ambiguous, impossible, or names nothing in the list, return no actions and put a short question in clarification.
    Levels and colour temperatures are percents from 0 to 100; fan speeds are gear numbers.
    Keep the summary to one short sentence. Do not add actions the user did not ask for.
    """

    private let controller: DeviceController
    private let defaults: UserDefaults

    public init(controller: DeviceController, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
    }

    public var isAvailable: Bool {
        AppSettings.plannerEnabled(from: defaults) && SystemLanguageModel.default.availability == .available
    }

    public var unavailableReason: String? {
        guard AppSettings.plannerEnabled(from: defaults) else { return "natural-language planning is turned off in Settings" }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "this Mac does not support Apple Intelligence"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is not enabled in System Settings"
            case .modelNotReady: return "the on-device model is still downloading"
            @unknown default: return "the on-device model is unavailable"
            }
        }
    }

    public func plan(_ utterance: String, devices: [DeviceSummary]) async throws -> ProposedPlan {
        guard isAvailable else { throw PlannerError.unavailable(unavailableReason ?? "unavailable") }
        let roster = Array(devices.prefix(AppSettings.plannerMaxDevices(from: defaults)))
        let controller = self.controller
        let tools: [any Tool] = [
            ListDevicesTool(provider: { await MainActor.run { controller.summaries() } }),
            FindDevicesTool(finder: { phrase in
                await MainActor.run {
                    let resolution = controller.resolve(DeviceQuery(text: phrase))
                    return (resolution.devices.map(controller.summary(for:)), resolution.isAmbiguous)
                }
            })
        ]
        let instructions = AppSettings.plannerInstructions(from: defaults, fallback: Self.defaultInstructions)
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        let prompt = "Devices:\n\(PlannerRegistry.render(roster))\n\nRequest: \(utterance)"
        do {
            let response = try await session.respond(to: prompt, generating: PlannedResponse.self)
            return Self.convert(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            throw PlannerError.failed(error.localizedDescription)
        }
    }

    /// Model output → proposal. Unknown actions are dropped into a
    /// clarification rather than guessed; identical commands on several
    /// devices collapse into one step so confirmation reads naturally.
    static func convert(_ response: PlannedResponse) -> ProposedPlan {
        var steps: [ProposedStep] = []
        var problems: [String] = []
        for action in response.actions {
            guard let command = command(for: action, problems: &problems) else { continue }
            if let index = steps.firstIndex(where: { $0.command == command }) {
                if !steps[index].deviceIDs.contains(action.deviceID) { steps[index].deviceIDs.append(action.deviceID) }
            } else {
                steps.append(ProposedStep(deviceIDs: [action.deviceID], command: command))
            }
        }
        let question = response.clarification.trimmingCharacters(in: .whitespacesAndNewlines)
        var clarification = question.isEmpty ? nil : question
        if steps.isEmpty, clarification == nil, !problems.isEmpty { clarification = problems.joined(separator: " ") }
        return ProposedPlan(steps: steps, summary: response.summary.trimmingCharacters(in: .whitespacesAndNewlines), clarification: clarification)
    }

    private static func command(for action: PlannedAction, problems: inout [String]) -> DeviceCommand? {
        switch action.action {
        case .turnOn: return .power(true)
        case .turnOff: return .power(false)
        case .open: return .cover(.open)
        case .close: return .cover(.close)
        case .stop: return .cover(.stop)
        case .setLevel:
            guard let value = action.value else { problems.append("No level was given."); return nil }
            return .level(Percent.clamp(value))
        case .setColorTemperature:
            guard let value = action.value else { problems.append("No colour temperature was given."); return nil }
            return .colorTemperature(Percent.clamp(value))
        case .setFanSpeed:
            guard let value = action.value else { problems.append("No fan speed was given."); return nil }
            return .fanSpeed(value)
        case .setMode:
            guard let mode = action.mode, !mode.isEmpty else { problems.append("No mode was given."); return nil }
            return .mode(mode)
        case .setColor:
            let grammar = CommandGrammar.standard
            let name = TextNormalizer.fold(action.color ?? "").trimmingCharacters(in: .whitespaces)
            if let percent = grammar.temperaturePhrases[name] { return .colorTemperature(percent) }
            if let rgb = grammar.colorNames[name] { return .color(rgb) }
            problems.append("I don't know the colour \"\(action.color ?? "")\".")
            return nil
        }
    }
}

#endif

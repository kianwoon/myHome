// Level-2 planner on Apple Foundation Models (on-device, macOS 26+).
//
// General rule: THE MODEL ONLY PROPOSES. It sees a compact device catalogue (handles,
// names, rooms, kinds, capabilities) plus bounded tools and a structured
// @Generable plan; every step still goes through DeviceController's policy,
// and the coordinator asks the user before running a model-authored plan.
// Availability is triple-gated: the framework must be importable, the OS
// must be macOS 26+, and SystemLanguageModel must report `.available`.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum PlannerFactory {
    /// The planner chosen in Settings (provider none = rule parser only), or nil.
    @MainActor
    public static func makePlanner(controller: DeviceController, defaults: UserDefaults = .standard,
                                   secrets: SecretStore = KeychainSecretStore(), session: URLSession = CloudPlanner.makeSession()) -> NaturalLanguagePlanner? {
        switch AppSettings.plannerProvider(from: defaults) {
        case .none:
            return nil
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) { return FoundationModelsPlanner(controller: controller, defaults: defaults) }
            #endif
            return nil
        case .anthropic, .openAICompatible:
            return CloudPlanner(controller: controller, defaults: defaults, secrets: secrets, session: session)
        }
    }

    /// The Jev router & matcher when enabled (independent of the planner provider), else nil.
    @MainActor
    public static func makeJevDecider(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore(),
                                      transport: JevTransport = URLSessionJevTransport()) -> JevCommandDecider? {
        guard AppSettings.jevEnabled(from: defaults) else { return nil }
        return JevCommandDecider(defaults: defaults, secrets: secrets, transport: transport)
    }

    /// Why the Apple on-device planner is off on this Mac; nil when it can run.
    @MainActor
    public static func platformNote() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return nil }
        #endif
        return "Natural-language planning needs macOS 26 or newer."
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
    @Guide(description: "The device handle (like d3) copied from the device list")
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
    let description = "Lists devices (handle|name|room|kind|state|capabilities), optionally filtered."
    let catalogue: PlannerCatalogue
    let provider: @Sendable () async -> [DeviceSummary]

    @Generable
    struct Arguments {
        @Guide(description: "Word to filter by room, group, kind or name; empty for all")
        var filter: String
    }

    func call(arguments: Arguments) async throws -> String {
        let all = await provider()
        let needle = TextNormalizer.fold(arguments.filter).trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? all : all.filter { device in
            TextNormalizer.fold(device.room).contains(needle) || TextNormalizer.fold(device.group ?? "").contains(needle)
                || device.kind.rawValue.contains(needle) || TextNormalizer.fold(device.name).contains(needle)
        }
        return shown.isEmpty ? "No devices match." : catalogue.render(shown)
    }
}

@available(macOS 26, *)
struct FindDevicesTool: Tool {
    let name = "findDevices"
    let description = "Finds the devices a phrase like 'study fan' refers to; says when it is ambiguous."
    let catalogue: PlannerCatalogue
    let finder: @Sendable (String) async -> (devices: [DeviceSummary], ambiguous: Bool)

    @Generable
    struct Arguments {
        @Guide(description: "The device phrase from the request")
        var phrase: String
    }

    func call(arguments: Arguments) async throws -> String {
        let found = await finder(arguments.phrase)
        if found.devices.isEmpty { return "No device matches \"\(arguments.phrase)\"." }
        let prefix = found.ambiguous ? "Ambiguous, ask the user which one:\n" : ""
        return prefix + catalogue.render(found.devices)
    }
}

@available(macOS 26, *)
@MainActor
public final class FoundationModelsPlanner: NaturalLanguagePlanner {
    // allow-hardcode: these are the model instructions (a prompt), reviewed
    // guidance that AppSettings.plannerInstructions can override at runtime.
    public static let defaultInstructions = """
    Turn a home-control request into device actions. Use only device handles (like d3) from the list or tool results.
    Call findDevices when a phrase could mean several devices or the device is not listed.
    If the request is ambiguous or impossible, return no actions and ask a short question in clarification.
    Levels are percents 0-100; fan speeds are gear numbers. Do not add actions that were not asked for.
    """

    private let controller: DeviceController
    private let defaults: UserDefaults

    public init(controller: DeviceController, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
    }

    public var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public var unavailableReason: String? {
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
        let budget = AppSettings.plannerCatalogueBudget(from: defaults)
        do {
            return try await attempt(utterance, devices: devices, budget: budget, narrowed: false)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else { throw PlannerError.failed(error.localizedDescription) }
            // One retry with a much smaller catalogue (best name matches only);
            // the tools can still reach the rest.
            let smaller = max(budget / AppSettings.plannerRetryShrink(from: defaults), AppSettings.plannerCatalogueBudgetRange.lowerBound)
            AppLog.assistant.error("planner context overflow; retrying with a \(smaller)-char catalogue")
            do {
                return try await attempt(utterance, devices: devices, budget: smaller, narrowed: true)
            } catch let again as LanguageModelSession.GenerationError {
                throw PlannerError.failed(again.localizedDescription)
            }
        }
    }

    /// One request = one fresh session: no transcript carries over between requests.
    private func attempt(_ utterance: String, devices: [DeviceSummary], budget: Int, narrowed: Bool) async throws -> ProposedPlan {
        let maxDevices = narrowed ? max(1, AppSettings.plannerMaxDevices(from: defaults) / AppSettings.plannerRetryShrink(from: defaults))
                                  : AppSettings.plannerMaxDevices(from: defaults)
        let catalogue = PlannerCatalogue(devices: devices, utterance: utterance, budget: budget, maxDevices: maxDevices,
                                         toolOutputBudget: AppSettings.plannerToolOutputBudget(from: defaults))
        let controller = self.controller
        let tools: [any Tool] = [
            ListDevicesTool(catalogue: catalogue, provider: { await MainActor.run { controller.summaries() } }),
            FindDevicesTool(catalogue: catalogue, finder: { phrase in
                await MainActor.run {
                    let resolution = controller.resolve(DeviceQuery(text: phrase))
                    return (resolution.devices.map(controller.summary(for:)), resolution.isAmbiguous)
                }
            })
        ]
        let instructions = AppSettings.plannerInstructions(from: defaults, fallback: Self.defaultInstructions)
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        let prompt = "Devices (\(PlannerCatalogue.columns)):\n\(catalogue.render())\n\nRequest: \(utterance)"
        let response = try await session.respond(to: prompt, generating: PlannedResponse.self)
        var plan = Self.convert(response.content)
        plan.steps = plan.steps.map { ProposedStep(deviceIDs: $0.deviceIDs.map(catalogue.id(forHandle:)), command: $0.command) }
        return plan
    }

    /// Model output → proposal (shared with the cloud planner).
    static func convert(_ response: PlannedResponse) -> ProposedPlan {
        PlanConverter.convert(PlanPayload(
            actions: response.actions.map { PlanPayload.Action(device: $0.deviceID, action: $0.action.rawValue, value: $0.value, mode: $0.mode, color: $0.color) },
            summary: response.summary, clarification: response.clarification))
    }
}

#endif

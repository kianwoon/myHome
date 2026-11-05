// Jev decider: matches a request the rule parser could not settle to ONE
// device and ONE action by asking Jev two choice questions (the jev_hat
// two-stage pattern from opencode):
//
//   Stage A — which device? Options are short catalogue handles (d1, d2 …)
//             described by name, room, kind and capabilities.
//   Stage B — which action? Options are only the actions THAT device
//             supports (CapabilityMap via DeviceSummary.capabilities).
//
// The stages are two sequential calls, not one batch: decision questions are
// independent, so Stage B's options cannot depend on Stage A's answer inside
// one request. When the parser already knows the command, only Stage A runs;
// a lone candidate (device or action) is taken without a call. Numeric values
// come from the transcript via the rule parser, never from Jev.
//
// Jev only ADVISES. An accepted decision becomes a proposal the coordinator
// confirms with the user; anything below the gate, unmeasured or failed is
// returned as `.unsure` so the user is asked — never guessed for.
import Foundation

@MainActor
public final class JevCommandDecider {
    /// Stage B option labels (wire-safe: [a-z-], ≤ 64 chars).
    public enum Action: String, CaseIterable, Sendable {
        case powerOn = "power-on", powerOff = "power-off", setLevel = "set-level", setSpeed = "set-speed"
        case setColorTemperature = "set-color-temperature", open, close, stop

        var capability: SemanticCapability {
            switch self {
            case .powerOn, .powerOff: return .power
            case .setLevel: return .level
            case .setSpeed: return .fanSpeed
            case .setColorTemperature: return .colorTemperature
            case .open, .close, .stop: return .openClose
            }
        }

        var needsValue: Bool { self == .setLevel || self == .setSpeed || self == .setColorTemperature }

        /// Short spoken phrase for "did you mean …?".
        public var phrase: String {
            switch self {
            case .powerOn: return "turn on"
            case .powerOff: return "turn off"
            case .setLevel: return "set the level"
            case .setSpeed: return "set the speed"
            case .setColorTemperature: return "set the colour temperature"
            case .open: return "open"
            case .close: return "close"
            case .stop: return "stop"
            }
        }

        // allow-hardcode: option descriptions sent to the classifier (the accuracy lever, jev.md §4.2).
        var criterion: String {
            switch self {
            case .powerOn: return "Switch the device on (turn on, start, power up, activate)."
            case .powerOff: return "Switch the device off (turn off, stop running, power down, shut off)."
            case .setLevel: return "Set brightness, position or level to a percentage (dim, brighten, set to N percent)."
            case .setSpeed: return "Set the fan speed or gear to a number (faster, slower, speed N)."
            case .setColorTemperature: return "Set the white colour temperature (warmer or cooler white, N percent cool)."
            case .open: return "Open the curtain, blind or cover."
            case .close: return "Close the curtain, blind or cover."
            case .stop: return "Stop a moving curtain, blind or cover."
            }
        }

        static func supported(by capabilities: [SemanticCapability]) -> [Action] {
            allCases.filter { capabilities.contains($0.capability) }
        }
    }

    public struct Unsure: Equatable, Sendable {
        /// Why Jev could not settle it (safe to show: no body, no key).
        public var reason: String
        /// Devices Jev leaned to, strongest first (empty when unmeasured).
        public var devices: [DeviceSummary]
        /// Set when the device was settled but the action was not.
        public var device: DeviceSummary?
        /// Actions Jev leaned to for `device`, strongest first.
        public var actions: [Action]
        /// The action was settled but the request carried no value.
        public var missingValue: Action?
    }

    public enum Outcome: Equatable, Sendable {
        case accepted(device: DeviceSummary, command: DeviceCommand, deviceStrength: Double?, actionStrength: Double?)
        case unsure(Unsure)
    }

    // allow-hardcode: the classifier questions (reviewed guidance, like CloudPlanner.defaultInstructions).
    nonisolated static let deviceQuestionID = "device"
    nonisolated static let actionQuestionID = "action"
    static let deviceInstructions = "Which smart-home device does the spoken request refer to? Each option is one device: its name, room, kind and what it can do. Pick the device the speaker means."
    static let actionInstructions = "What does the spoken request want done to the chosen device? Pick the one action that matches."
    static let requestStatePrefix = "Spoken smart-home request (may contain speech-recognition errors): "
    static let chosenDeviceStatePrefix = "Chosen device: "

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let transport: JevTransport
    private let environment: [String: String]
    private let parser: VoiceCommandParser

    public init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore(),
                transport: JevTransport = URLSessionJevTransport(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                parser: VoiceCommandParser = VoiceCommandParser()) {
        self.defaults = defaults
        self.secrets = secrets
        self.transport = transport
        self.environment = environment
        self.parser = parser
    }

    /// Settings are read on every request.
    public var client: JevClient {
        JevClient(config: .fromDefaults(defaults), secret: JevClient.resolveSecret(secrets: secrets, environment: environment), transport: transport)
    }

    public var unavailableReason: String? {
        JevClient.problem(with: .fromDefaults(defaults), key: JevClient.resolveKey(secrets: secrets, environment: environment))
    }

    public var isAvailable: Bool { unavailableReason == nil }

    public func testConnection() async -> String { await client.testConnection() }

    // MARK: - Decide

    /// `devices` are the candidates (all devices, or the parser's ambiguous
    /// set); `known` is the command the parser already understood, if any.
    public func decide(_ utterance: String, devices: [DeviceSummary], known: DeviceCommand?) async -> Outcome {
        let client = self.client
        var pool = devices.filter(\.isControllable)
        if let known { pool = pool.filter { $0.capabilities.contains(known.capability) } }
        guard !pool.isEmpty else { return .unsure(Self.unsure("no device can do that")) }
        let state = Self.requestStatePrefix + "\u{201C}" + utterance + "\u{201D}"

        // Stage A — device.
        let device: DeviceSummary
        var deviceStrength: Double?
        if pool.count == 1 {
            device = pool[0]
        } else {
            let catalogue = PlannerCatalogue(devices: pool, utterance: utterance,
                                             budget: AppSettings.jevCatalogueBudget,
                                             maxDevices: min(AppSettings.plannerMaxDevices(from: defaults), AppSettings.jevChoiceOptionsRange.upperBound),
                                             toolOutputBudget: AppSettings.plannerToolOutputBudget(from: defaults))
            let shown = catalogue.shown
            if shown.count == 1 {
                device = shown[0]
            } else {
                let labels = shown.map { catalogue.handle(for: $0.id) }
                let criteria = Dictionary(uniqueKeysWithValues: zip(labels, shown.map(Self.describe)))
                let question = JevQuestion(instructions: Self.deviceInstructions, criteria: criteria)
                switch await ask(client, state: state, id: Self.deviceQuestionID, question: question, labels: labels) {
                case .failure(let failure):
                    return .unsure(Self.unsure(failure.reason))
                case .success(.accepted(let label, let strength)):
                    guard let picked = shown.first(where: { catalogue.handle(for: $0.id) == label }) else {
                        return .unsure(Self.unsure("the answer named an unknown device"))
                    }
                    device = picked
                    deviceStrength = strength
                case .success(.belowGate(_, let strength, let ranked)):
                    let leaning = ranked.prefix(AppSettings.jevSuggestionCount).compactMap { label in
                        shown.first { catalogue.handle(for: $0.id) == label }
                    }
                    return .unsure(Unsure(reason: Self.belowGateReason(strength, gate: client.config.gate), devices: leaning, device: nil, actions: [], missingValue: nil))
                case .success(.unmeasured(let reason)):
                    return .unsure(Self.unsure(reason))
                }
            }
        }

        // Stage B — action (skipped when the parser already knows it).
        if let known {
            return .accepted(device: device, command: known, deviceStrength: deviceStrength, actionStrength: nil)
        }
        let actions = Action.supported(by: device.capabilities)
        let action: Action
        var actionStrength: Double?
        switch actions.count {
        case 0:
            return .unsure(Unsure(reason: "\(device.name) has no action Jev can choose", devices: [device], device: device, actions: [], missingValue: nil))
        case 1:
            action = actions[0]
        default:
            let labels = actions.map(\.rawValue)
            let criteria = Dictionary(uniqueKeysWithValues: actions.map { ($0.rawValue, $0.criterion) })
            let question = JevQuestion(instructions: Self.actionInstructions, criteria: criteria)
            let stageState = state + "\n" + Self.chosenDeviceStatePrefix + Self.describe(device)
            switch await ask(client, state: stageState, id: Self.actionQuestionID, question: question, labels: labels) {
            case .failure(let failure):
                return .unsure(Unsure(reason: failure.reason, devices: [device], device: device, actions: [], missingValue: nil))
            case .success(.accepted(let label, let strength)):
                guard let picked = Action(rawValue: label) else { return .unsure(Self.unsure("the answer named an unknown action")) }
                action = picked
                actionStrength = strength
            case .success(.belowGate(_, let strength, let ranked)):
                let leaning = ranked.prefix(AppSettings.jevSuggestionCount).compactMap(Action.init(rawValue:))
                return .unsure(Unsure(reason: Self.belowGateReason(strength, gate: client.config.gate), devices: [device], device: device, actions: leaning, missingValue: nil))
            case .success(.unmeasured(let reason)):
                return .unsure(Unsure(reason: reason, devices: [device], device: device, actions: [], missingValue: nil))
            }
        }
        guard let command = command(for: action, utterance: utterance) else {
            return .unsure(Unsure(reason: "no value was heard", devices: [device], device: device, actions: [action], missingValue: action))
        }
        return .accepted(device: device, command: command, deviceStrength: deviceStrength, actionStrength: actionStrength)
    }

    /// One stage: call, then fold against the offered labels.
    private func ask(_ client: JevClient, state: String, id: String, question: JevQuestion, labels: [String]) async -> Result<JevVerdict, StageFailure> {
        switch await client.ask(state: state, questions: [id: question]) {
        case .failure(let failure):
            AppLog.assistant.info("jev \(id, privacy: .public) failed open: \(failure.message, privacy: .public)")
            return .failure(StageFailure(failure.message))
        case .success(let answers):
            let verdict = JevClient.fold(answers.rows[id], labels: labels, threshold: client.config.threshold)
            AppLog.assistant.info("jev \(id, privacy: .public) verdict=\(Self.verdictName(verdict), privacy: .public)")
            return .success(verdict)
        }
    }

    struct StageFailure: Error, Equatable { let reason: String; init(_ reason: String) { self.reason = reason } }

    private func command(for action: Action, utterance: String) -> DeviceCommand? {
        switch action {
        case .powerOn: return .power(true)
        case .powerOff: return .power(false)
        case .open: return .cover(.open)
        case .close: return .cover(.close)
        case .stop: return .cover(.stop)
        case .setLevel: return parser.value(in: utterance).map { .level(Percent.clamp($0)) }
        case .setSpeed: return parser.value(in: utterance).map { .fanSpeed($0) }
        case .setColorTemperature: return parser.value(in: utterance).map { .colorTemperature(Percent.clamp($0)) }
        }
    }

    // MARK: - Helpers

    static func describe(_ device: DeviceSummary) -> String {
        var parts = [device.name]
        if !device.room.isEmpty { parts.append("room \(device.room)") }
        parts.append(device.kind.rawValue)
        parts.append("can " + device.capabilities.map(\.rawValue).joined(separator: ","))
        return parts.joined(separator: "; ")
    }

    private static func unsure(_ reason: String) -> Unsure {
        Unsure(reason: reason, devices: [], device: nil, actions: [], missingValue: nil)
    }

    static func belowGateReason(_ strength: Double, gate: Double) -> String {
        "best match \(percent(strength)), needs \(percent(gate))"
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private static func verdictName(_ verdict: JevVerdict) -> String {
        switch verdict {
        case .accepted: return "accepted"
        case .belowGate: return "below_gate"
        case .unmeasured: return "unmeasured"
        }
    }
}

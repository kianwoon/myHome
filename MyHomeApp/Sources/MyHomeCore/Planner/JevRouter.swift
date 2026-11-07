// Jev router: ONE decisions request that classifies a request the rule parser
// could not understand into command / query / inference / other. The three
// query-detail questions (kind, state, aggregation) ride in the SAME request
// — decision questions are independent, so they cannot be asked "only if
// query" — and are read only when the route is `query`.
//
// Jev never answers the question itself: for `query` it only picks the
// shape (which kind, on/off, count/list/yes-no); DeviceQueryAnswerer counts
// from the registry. Every row is gated on probabilities[choice] (JevClient
// .fold); below the gate, unmeasured or failed → `.unsure` (fail open).
import Foundation

public extension JevCommandDecider {
    /// Route labels (wire-safe: [a-z-]).
    enum RouteLabel: String, CaseIterable, Sendable {
        case command, query, inference, other

        // allow-hardcode: option descriptions sent to the classifier (the accuracy lever, jev.md §4.2).
        var criterion: String {
            switch self {
            case .command:
                return "An instruction to change a device: turn on or off, set a level, speed or colour, open, close or stop something (\u{201C}switch off the hall light\u{201D}, \u{201C}fan to three\u{201D})."
            case .query:
                return "A question about the current state or number of devices, changing nothing (\u{201C}how many lights are on\u{201D}, \u{201C}is the fan running\u{201D}, \u{201C}which lamps are off\u{201D})."
            case .inference:
                return "Describes a condition, feeling or need without naming an action, so the action must be inferred (\u{201C}the room is stuffy\u{201D}, \u{201C}it's too dark in here\u{201D}, \u{201C}I'm cold\u{201D})."
            case .other:
                return "Anything else: chit-chat, a question unrelated to the home's devices, or noise."
            }
        }
    }

    enum RouteOutcome: Equatable, Sendable {
        case command(strength: Double)
        /// The question's shape; the answer is computed from the registry.
        case query(StateQuery, strength: Double)
        case inference(strength: Double)
        case other(strength: Double)
        /// Below the gate, unmeasured or failed: the caller falls back.
        case unsure(String)
    }

    // allow-hardcode: the classifier questions and option descriptions (reviewed guidance).
    nonisolated static let routeQuestionID = "route"
    nonisolated static let kindQuestionID = "kind"
    nonisolated static let stateQuestionID = "state"
    nonisolated static let aggregationQuestionID = "aggregation"
    nonisolated static let anyKindLabel = "any"
    static let routeInstructions = "What kind of smart-home request is this? Pick the one category that fits the spoken words."
    static let kindInstructions = "If the request asks about devices, which kind of device does it ask about? Pick any when it asks about all devices or no kind fits."
    static let stateInstructions = "If the request asks about devices, which power state does it ask about?"
    static let aggregationInstructions = "If the request asks about devices, what answer does it want?"
    static let stateCriteria: [String: String] = [
        StateQuery.State.on.rawValue: "Devices that are on, running or lit.",
        StateQuery.State.off.rawValue: "Devices that are off or not running.",
        StateQuery.State.any.rawValue: "No particular state: all the devices of that kind.",
    ]
    static let aggregationCriteria: [String: String] = [
        StateQuery.Aggregation.count.rawValue: "A number (\u{201C}how many …\u{201D}).",
        StateQuery.Aggregation.list.rawValue: "The names of the devices (\u{201C}which …\u{201D}, \u{201C}what … are on\u{201D}).",
        StateQuery.Aggregation.is.rawValue: "A yes or no (\u{201C}is the …\u{201D}, \u{201C}are any …\u{201D}).",
    ]

    // allow-hardcode: classifier descriptions of each device kind.
    static func kindCriterion(_ kind: DeviceKind) -> String {
        switch kind {
        case .fan: return "Fans (ceiling, desk or standing fans)."
        case .curtain: return "Curtains, blinds, shades and covers."
        case .light: return "Lights, lamps, bulbs and LED strips."
        case .plug: return "Smart plugs, sockets, outlets and switches."
        case .climate: return "Air conditioners, heaters and thermostats."
        case .purifier: return "Air purifiers and filters."
        case .kettle: return "Kettles and kitchen appliances."
        case .speaker: return "Speakers and hi-fi (KEF)."
        case .unknown: return "Other devices."
        }
    }

    /// One request; the query-detail rows are read only when the route is `query`.
    func route(_ utterance: String, devices: [DeviceSummary]) async -> RouteOutcome {
        let client = self.client
        let state = Self.requestStatePrefix + "\u{201C}" + utterance + "\u{201D}"
        var seen = Set<DeviceKind>()
        let kinds = devices.map(\.kind).filter { $0 != .unknown && seen.insert($0).inserted }

        var labels: [String: [String]] = [Self.routeQuestionID: RouteLabel.allCases.map(\.rawValue)]
        var questions: [String: JevQuestion] = [
            Self.routeQuestionID: JevQuestion(instructions: Self.routeInstructions,
                                              criteria: Dictionary(uniqueKeysWithValues: RouteLabel.allCases.map { ($0.rawValue, $0.criterion) })),
            Self.stateQuestionID: JevQuestion(instructions: Self.stateInstructions, criteria: Self.stateCriteria),
            Self.aggregationQuestionID: JevQuestion(instructions: Self.aggregationInstructions, criteria: Self.aggregationCriteria),
        ]
        labels[Self.stateQuestionID] = StateQuery.State.allCases.map(\.rawValue)
        labels[Self.aggregationQuestionID] = StateQuery.Aggregation.allCases.map(\.rawValue)
        if !kinds.isEmpty {
            var criteria = Dictionary(uniqueKeysWithValues: kinds.map { ($0.rawValue, Self.kindCriterion($0)) })
            criteria[Self.anyKindLabel] = Self.kindCriterion(.unknown) + " Or all kinds."
            questions[Self.kindQuestionID] = JevQuestion(instructions: Self.kindInstructions, criteria: criteria)
            labels[Self.kindQuestionID] = kinds.map(\.rawValue) + [Self.anyKindLabel]
        }

        let answers: JevAnswers
        switch await client.ask(state: state, questions: questions) {
        case .failure(let failure):
            AppLog.assistant.info("jev route failed open: \(failure.message, privacy: .public)")
            return .unsure(failure.message)
        case .success(let value):
            answers = value
        }
        func verdict(_ id: String) -> JevVerdict {
            JevClient.fold(answers.rows[id], labels: labels[id] ?? [], threshold: client.config.threshold)
        }
        let route = verdict(Self.routeQuestionID)
        AppLog.assistant.info("jev route verdict=\(String(describing: route), privacy: .public)")
        guard case .accepted(let label, let strength) = route, let picked = RouteLabel(rawValue: label) else {
            return .unsure(Self.unsureReason(route, gate: client.config.gate))
        }
        switch picked {
        case .command: return .command(strength: strength)
        case .inference: return .inference(strength: strength)
        case .other: return .other(strength: strength)
        case .query:
            var kind: DeviceKind?
            if labels[Self.kindQuestionID] != nil {
                let kindVerdict = verdict(Self.kindQuestionID)
                guard case .accepted(let kindLabel, _) = kindVerdict else {
                    return .unsure("which devices: " + Self.unsureReason(kindVerdict, gate: client.config.gate))
                }
                kind = kindLabel == Self.anyKindLabel ? nil : DeviceKind(rawValue: kindLabel)
            }
            let stateVerdict = verdict(Self.stateQuestionID)
            guard case .accepted(let stateLabel, _) = stateVerdict, let powerState = StateQuery.State(rawValue: stateLabel) else {
                return .unsure("which state: " + Self.unsureReason(stateVerdict, gate: client.config.gate))
            }
            let aggregationVerdict = verdict(Self.aggregationQuestionID)
            guard case .accepted(let aggregationLabel, _) = aggregationVerdict,
                  let aggregation = StateQuery.Aggregation(rawValue: aggregationLabel) else {
                return .unsure("what answer: " + Self.unsureReason(aggregationVerdict, gate: client.config.gate))
            }
            return .query(StateQuery(kind: kind, state: powerState, aggregation: aggregation), strength: strength)
        }
    }

    internal static func unsureReason(_ verdict: JevVerdict, gate: Double) -> String {
        switch verdict {
        case .accepted: return "unexpected answer"
        case .belowGate(_, let strength, _): return belowGateReason(strength, gate: gate)
        case .unmeasured(let reason): return reason
        }
    }
}

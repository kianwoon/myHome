// Orchestrates one conversation turn: text/voice in → Level-1 grammar →
// (fallback) Level-2 planner → DeviceController → reply. Owns the pending
// confirmation so "yes"/"no" can finish a multi-device or ambiguous request.
// Everything that touches a device still goes through DeviceController.
import Combine
import Foundation

public struct AssistantReply: Equatable {
    public enum Kind: Equatable {
        case executed, needsConfirmation, ambiguous, status, planned, info, error
    }

    public let kind: Kind
    public let text: String
    public let result: CommandResult?
    /// How the reply was produced: "grammar" (Level 1) or "model" (Level 2).
    public let source: String

    public init(kind: Kind, text: String, result: CommandResult? = nil, source: String) {
        self.kind = kind
        self.text = text
        self.result = result
        self.source = source
    }
}

@MainActor
public final class AssistantCoordinator: ObservableObject {
    public static let grammarSource = "grammar"
    public static let modelSource = "model"

    public let controller: DeviceController
    public let parser: VoiceCommandParser
    public var planner: NaturalLanguagePlanner?

    @Published public private(set) var replies: [AssistantReply] = []
    @Published public private(set) var isBusy = false
    /// Requests waiting for "yes" (one per planned step).
    @Published public private(set) var pending: [CommandRequest] = []
    /// Devices the user must pick between after an ambiguous request.
    @Published public private(set) var pendingChoice: (command: DeviceCommand, candidates: [DeviceSummary])?

    public init(controller: DeviceController, parser: VoiceCommandParser = VoiceCommandParser(), planner: NaturalLanguagePlanner? = nil) {
        self.controller = controller
        self.parser = parser
        self.planner = planner
    }

    public var hasPendingConfirmation: Bool { !pending.isEmpty }

    // MARK: - Entry points

    /// Handles one utterance from any interaction layer and returns the reply.
    @discardableResult
    public func handle(_ utterance: String, origin: CommandOrigin) async -> AssistantReply {
        isBusy = true
        defer { isBusy = false }
        let reply = await process(utterance, origin: origin)
        replies.append(reply)
        return reply
    }

    /// Runs every pending request (the user said yes).
    @discardableResult
    public func confirmPending() async -> AssistantReply? {
        guard let reply = await runPending() else { return nil }
        replies.append(reply)
        return reply
    }

    @discardableResult
    public func cancelPending() -> AssistantReply {
        let reply = dropPending()
        replies.append(reply)
        return reply
    }

    /// The user picked one of the ambiguous candidates.
    @discardableResult
    public func choose(deviceID: String, origin: CommandOrigin) async -> AssistantReply? {
        guard let choice = pendingChoice, let device = controller.device(id: deviceID) else { return nil }
        let reply = await runChoice(choice.command, device: device, origin: origin)
        replies.append(reply)
        return reply
    }

    public func clearHistory() {
        replies = []
    }

    // MARK: - Processing

    private func runPending() async -> AssistantReply? {
        guard !pending.isEmpty else { return nil }
        let requests = pending
        pending = []
        var results: [CommandResult] = []
        for var request in requests {
            request.confirmed = true   // the user just said yes
            results.append(await controller.perform(request))
        }
        let text = results.map(\.spokenSummary).joined(separator: " ")
        return AssistantReply(kind: .executed, text: text, result: results.last, source: Self.grammarSource)
    }

    private func dropPending() -> AssistantReply {
        pending = []
        pendingChoice = nil
        return AssistantReply(kind: .info, text: "Cancelled.", source: Self.grammarSource)
    }

    private func runChoice(_ command: DeviceCommand, device: Device, origin: CommandOrigin) async -> AssistantReply {
        pendingChoice = nil
        let request = CommandRequest(resolution: .single(device), command: command, origin: origin, confirmed: true)
        return reply(for: await controller.perform(request), source: Self.grammarSource)
    }

    private func process(_ utterance: String, origin: CommandOrigin) async -> AssistantReply {
        let intent = parser.parse(utterance)
        // An answer to "which one?": a bare name ("the desk one") keeps the
        // pending command; a full command names both the device and a new command.
        if let choice = pendingChoice {
            switch intent {
            case .command(let query, let command):
                if let picked = pickCandidate(forCommandQuery: query, from: choice.candidates) {
                    return await runChoice(command, device: picked, origin: origin)
                }
            case .unknown:
                if let picked = pickCandidate(DeviceQuery(text: Self.answerText(utterance)), from: choice.candidates) {
                    return await runChoice(choice.command, device: picked, origin: origin)
                }
            default:
                break
            }
        }
        switch intent {
        case .confirm:
            if let reply = await runPending() { return reply }
            return AssistantReply(kind: .info, text: "Nothing is waiting for confirmation.", source: Self.grammarSource)
        case .cancel:
            if hasPendingConfirmation || pendingChoice != nil { return dropPending() }
            return AssistantReply(kind: .info, text: "Nothing to cancel.", source: Self.grammarSource)
        case .status(let query):
            return statusReply(query)
        case .command(let query, let command):
            // A new command supersedes anything still waiting for a yes.
            pending = []
            pendingChoice = nil
            let result = await controller.perform(command, on: query, origin: origin)
            if case .nothingToDo = result.disposition, let planner, planner.isAvailable {
                // The grammar understood the shape but not the device: let the
                // model try with the registry in front of it.
                return await planWithModel(utterance, origin: origin)
            }
            return reply(for: result, source: Self.grammarSource)
        case .unknown:
            if let planner, planner.isAvailable {
                return await planWithModel(utterance, origin: origin)
            }
            let note = planner?.unavailableReason.map { " (\($0))" } ?? ""
            return AssistantReply(kind: .error, text: "Sorry, I didn't understand that\(note).", source: Self.grammarSource)
        }
    }

    /// Words that only point back at the question ("the desk ONE"), not at a device.
    private static let answerFillerWords: Set<String> = ["one", "ones"]

    private static func answerText(_ utterance: String) -> String {
        let kept = TextNormalizer.rawTokens(utterance).filter { !answerFillerWords.contains($0) }
        return kept.isEmpty ? utterance : kept.joined(separator: " ")
    }

    /// A short answer to an ambiguity question ("the desk one", "desk lamp"):
    /// the answer has to CLEARLY single out ONE of the offered candidates.
    /// A partial match is only a suggestion and never picks a device.
    private func pickCandidate(_ query: DeviceQuery, from candidates: [DeviceSummary]) -> Device? {
        let devices = candidates.compactMap { controller.device(id: $0.id) }
        let resolver = DeviceResolver(devices: devices, config: controller.resolverConfig, vocabulary: controller.vocabulary)
        if case .single(let device) = resolver.resolve(query) { return device }
        return nil
    }

    /// A full new command ("turn on the kitchen light") while a choice is open:
    /// resolve it against ALL devices first, so a command naming something
    /// outside the open choice is never bent onto one of its candidates.
    private func pickCandidate(forCommandQuery query: DeviceQuery, from candidates: [DeviceSummary]) -> Device? {
        if case .single(let device) = controller.resolve(query) {
            return candidates.contains { $0.id == device.id } ? device : nil
        }
        return pickCandidate(query, from: candidates)
    }

    private func statusReply(_ query: DeviceQuery) -> AssistantReply {
        let resolution = controller.resolve(query)
        let devices = resolution.devices
        guard !devices.isEmpty else {
            return AssistantReply(kind: .error, text: "No device matches that request.", source: Self.grammarSource)
        }
        let text = devices.map { CommandPhrasing.describe(controller.summary(for: $0)) }.joined(separator: ". ") + "."
        return AssistantReply(kind: .status, text: text, source: Self.grammarSource)
    }

    private func reply(for result: CommandResult, source: String) -> AssistantReply {
        switch result.disposition {
        case .executed:
            return AssistantReply(kind: .executed, text: result.spokenSummary, result: result, source: source)
        case .needsConfirmation:
            if let request = result.pendingRequest { pending.append(request) }
            return AssistantReply(kind: .needsConfirmation, text: result.spokenSummary, result: result, source: source)
        case .ambiguous(let candidates):
            pendingChoice = (result.command, candidates)
            return AssistantReply(kind: .ambiguous, text: result.spokenSummary, result: result, source: source)
        case .nothingToDo:
            return AssistantReply(kind: .error, text: result.spokenSummary, result: result, source: source)
        }
    }

    // MARK: - Level 2

    private func planWithModel(_ utterance: String, origin: CommandOrigin) async -> AssistantReply {
        guard let planner else {
            return AssistantReply(kind: .error, text: "Sorry, I didn't understand that.", source: Self.grammarSource)
        }
        let plan: ProposedPlan
        do {
            plan = try await planner.plan(utterance, devices: controller.summaries())
        } catch {
            AppLog.assistant.error("planner failed: \(String(describing: error))")
            return AssistantReply(kind: .error, text: "The on-device model couldn't plan that: \(Self.message(for: error)).", source: Self.modelSource)
        }
        if let question = plan.clarification, plan.steps.isEmpty {
            return AssistantReply(kind: .ambiguous, text: question, source: Self.modelSource)
        }
        guard !plan.steps.isEmpty else {
            return AssistantReply(kind: .error, text: "The model proposed nothing for that request.", source: Self.modelSource)
        }
        // Validate every id against the registry; the model only proposes.
        var requests: [CommandRequest] = []
        var unknownIDs: [String] = []
        for step in plan.steps {
            let devices = step.deviceIDs.compactMap { controller.device(id: $0) }
            unknownIDs.append(contentsOf: step.deviceIDs.filter { id in !devices.contains { $0.id == id } })
            guard !devices.isEmpty else { continue }
            let resolution: Resolution = devices.count == 1 ? .single(devices[0]) : .set(devices, scope: .all)
            requests.append(CommandRequest(resolution: resolution, command: step.command, origin: .model, confirmed: false))
        }
        if requests.isEmpty {
            return AssistantReply(kind: .error, text: "The model named devices I don't know (\(unknownIDs.joined(separator: ", "))).", source: Self.modelSource)
        }
        // A model-authored plan is always confirmed first, whatever its size:
        // the user sees exactly what will run before anything runs.
        pending = requests
        let lines = requests.map { request in
            CommandPhrasing.action(request.command, target: CommandPhrasing.targetPhrase(request.resolution.devices.map(controller.summary(for:)),
                                                                                        scope: DeviceController.scope(of: request.resolution)))
        }
        let text = (plan.summary.isEmpty ? "" : plan.summary + " ") + "Plan: " + lines.joined(separator: "; ") + ". Go ahead?"
        return AssistantReply(kind: .needsConfirmation, text: text, source: Self.modelSource)
    }

    static func message(for error: Error) -> String {
        if case PlannerError.unavailable(let text) = error { return text }
        if case PlannerError.failed(let text) = error { return text }
        return error.localizedDescription
    }
}

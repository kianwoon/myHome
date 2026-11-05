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
    /// How the reply was produced: "grammar" (Level 1), "model" (Level 2) or "jev" (Jev decider).
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
    /// Replies produced by the Jev decider (a choice classifier).
    public static let jevSource = "jev"
    /// Lead-in when Jev could not settle a request and the user is asked.
    public static let jevUnsureLead = "Jev wasn't sure"
    /// Reply when a voice session ended with no recognised words.
    public static let nothingHeardText = "I didn't hear anything."

    public let controller: DeviceController
    public let parser: VoiceCommandParser
    public var planner: NaturalLanguagePlanner?
    /// Set when Settings → AI Models enables Jev (router & matcher). It only
    /// ADVISES: an accepted match is always confirmed before it runs.
    public var jevDecider: JevCommandDecider?
    public var timeouts: AssistantTimeouts
    /// State questions name at most this many devices (AppSettings.stateQueryListMax).
    public var stateQueryListMax = AppSettings.stateQueryListMax()
    private var activeTask: Task<AssistantReply, Never>?

    @Published public private(set) var replies: [AssistantReply] = []
    @Published public private(set) var isBusy = false
    /// Requests waiting for "yes" (one per planned step).
    @Published public private(set) var pending: [CommandRequest] = []
    /// Devices the user must pick between after an ambiguous request.
    @Published public private(set) var pendingChoice: (command: DeviceCommand, candidates: [DeviceSummary])?

    public init(controller: DeviceController, parser: VoiceCommandParser = VoiceCommandParser(), planner: NaturalLanguagePlanner? = nil,
                timeouts: AssistantTimeouts = AssistantTimeouts()) {
        self.timeouts = timeouts
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
        defer { isBusy = false; activeTask = nil }
        let task = Task { await process(utterance, origin: origin) }
        activeTask = task
        let reply = await task.value
        replies.append(reply)
        return reply
    }

    /// Abandons the request in flight (the command bar's Cancel). The device
    /// write itself may still complete; only the wait is dropped.
    public func cancelActive() {
        activeTask?.cancel()
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

    /// A voice session ended without any recognised words: say so (it is
    /// not the same failure as words that match no command).
    @discardableResult
    public func noteNothingHeard() -> AssistantReply {
        AppLog.assistant.info("voice session ended with an empty transcript")
        let reply = AssistantReply(kind: .info, text: Self.nothingHeardText, source: Self.grammarSource)
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
            guard let result = await boundedPerform(request) else { return timeoutReply() }
            results.append(result)
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
        guard let result = await boundedPerform(request) else { return timeoutReply() }
        return reply(for: result, source: Self.grammarSource)
    }

    private func process(_ utterance: String, origin: CommandOrigin) async -> AssistantReply {
        let intent = parser.parse(utterance)
        if origin == .voice {
            AppLog.assistant.debug("voice utterance: \(utterance, privacy: .private) parsed=\(Self.intentName(intent), privacy: .public)")
        }
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
        case .stateQuery(let query):
            // Counted from the registry by code: no model, no network.
            return AssistantReply(kind: .status, text: DeviceQueryAnswerer.answer(query, devices: controller.summaries(), listMax: stateQueryListMax),
                                  source: Self.grammarSource)
        case .command(let query, let command):
            // A new command supersedes anything still waiting for a yes.
            pending = []
            pendingChoice = nil
            let controller = self.controller
            guard let result = await Deadline.run(seconds: timeouts.command, { @MainActor in
                await controller.perform(command, on: query, origin: origin)
            }) else { return timeoutReply() }
            // The grammar understood the command but not the device: Jev picks
            // the device (Stage A only), and the user confirms.
            if let jevDecider, jevDecider.isAvailable {
                switch result.disposition {
                case .nothingToDo:
                    return await decideWithJev(utterance, origin: origin, known: command, candidates: controller.summaries(), fallback: result)
                case .ambiguous(let candidates):
                    return await decideWithJev(utterance, origin: origin, known: command, candidates: candidates, fallback: result)
                default:
                    break
                }
            }
            if case .nothingToDo = result.disposition, let planner, planner.isAvailable {
                // The grammar understood the shape but not the device: let the
                // model try with the registry in front of it.
                return await planWithModel(utterance, origin: origin)
            }
            return reply(for: result, source: Self.grammarSource)
        case .unknown:
            if let jevDecider, jevDecider.isAvailable {
                pending = []
                pendingChoice = nil
                return await routeWithJev(utterance, origin: origin, jev: jevDecider)
            }
            if let planner, planner.isAvailable {
                return await planWithModel(utterance, origin: origin)
            }
            let note = (planner?.unavailableReason ?? jevDecider?.unavailableReason).map { " (\($0))" } ?? ""
            AppLog.assistant.info("utterance not understood origin=\(String(describing: origin), privacy: .public)")
            return AssistantReply(kind: .error, text: Self.notUnderstoodText(utterance, origin: origin, note: note),
                                  source: Self.grammarSource)
        }
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

    private func boundedPerform(_ request: CommandRequest) async -> CommandResult? {
        let controller = self.controller
        return await Deadline.run(seconds: timeouts.command) { @MainActor in await controller.perform(request) }
    }

    private func timeoutReply() -> AssistantReply {
        let text = Task.isCancelled ? "Cancelled." : "That took too long; the device may still apply it."
        return AssistantReply(kind: Task.isCancelled ? .info : .error, text: text, source: Self.grammarSource)
    }

    private func planWithModel(_ utterance: String, origin: CommandOrigin) async -> AssistantReply {
        guard let planner else {
            return AssistantReply(kind: .error, text: Self.notUnderstoodText(utterance, origin: origin, note: ""),
                                  source: Self.grammarSource)
        }
        let plan: ProposedPlan
        let summaries = controller.summaries()
        let outcome = await Deadline.run(seconds: timeouts.planner) { @MainActor () -> Result<ProposedPlan, PlannerFailure> in
            do { return .success(try await planner.plan(utterance, devices: summaries)) }
            catch { return .failure(PlannerFailure(error)) }
        }
        guard let outcome else {
            AppLog.assistant.error("planner timed out or was cancelled")
            let text = Task.isCancelled ? "Cancelled." : "The planner took too long to plan that. Try rephrasing the request."
            return AssistantReply(kind: Task.isCancelled ? .info : .error, text: text, source: Self.modelSource)
        }
        switch outcome {
        case .success(let proposed):
            plan = proposed
        case .failure(let failure):
            AppLog.assistant.error("planner failed: \(String(describing: failure.error))")
            return AssistantReply(kind: .error, text: "The planner couldn't plan that: \(Self.message(for: failure.error)).", source: Self.modelSource)
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

    // MARK: - Jev router

    /// `.unknown` with Jev on: one route call, then
    ///   command   → Jev matcher (device, action), confirmed before it runs;
    ///   query     → DeviceQueryAnswerer (counts from code, never the model);
    ///   inference → the Cloud LLM planner if available (plan confirmed), else
    ///               a hint to configure one — nothing ever runs here;
    ///   other     → the not-understood reply;
    ///   unsure    → the planner if available, else the matcher (old path).
    private func routeWithJev(_ utterance: String, origin: CommandOrigin, jev: JevCommandDecider) async -> AssistantReply {
        let summaries = controller.summaries()
        let outcome = await Deadline.run(seconds: timeouts.planner) { @MainActor in
            await jev.route(utterance, devices: summaries)
        }
        if Task.isCancelled { return AssistantReply(kind: .info, text: "Cancelled.", source: Self.jevSource) }
        let plannerReady = planner?.isAvailable == true
        switch outcome ?? .unsure("it took too long") {
        case .command:
            return await decideWithJev(utterance, origin: origin, known: nil, candidates: summaries, fallback: nil)
        case .query(let query, _):
            return AssistantReply(kind: .status, text: DeviceQueryAnswerer.answer(query, devices: controller.summaries(), listMax: stateQueryListMax),
                                  source: Self.jevSource)
        case .inference:
            if plannerReady { return await planWithModel(utterance, origin: origin) }
            return AssistantReply(kind: .info, text: Self.inferenceNeedsPlannerText(utterance, origin: origin, reason: planner?.unavailableReason),
                                  source: Self.jevSource)
        case .other:
            return AssistantReply(kind: .error, text: Self.notUnderstoodText(utterance, origin: origin, note: ""), source: Self.jevSource)
        case .unsure(let reason):
            AppLog.assistant.info("jev route unsure: \(reason, privacy: .public)")
            if plannerReady { return await planWithModel(utterance, origin: origin) }
            return await decideWithJev(utterance, origin: origin, known: nil, candidates: summaries, fallback: nil)
        }
    }

    // MARK: - Jev decider

    /// Jev chooses (device, then action); the coordinator turns an accepted
    /// choice into a PROPOSAL that waits for "yes" — exactly like a model plan.
    /// Below gate, unmeasured or failed: fall back to the parser's answer and
    /// ask the user, offering what Jev leaned to. Nothing runs on a guess.
    private func decideWithJev(_ utterance: String, origin: CommandOrigin, known: DeviceCommand?,
                               candidates: [DeviceSummary], fallback: CommandResult?) async -> AssistantReply {
        guard let jevDecider else {
            return AssistantReply(kind: .error, text: Self.notUnderstoodText(utterance, origin: origin, note: ""), source: Self.grammarSource)
        }
        let heard = Self.heardText(utterance, origin: origin)
        let outcome = await Deadline.run(seconds: timeouts.planner) { @MainActor in
            await jevDecider.decide(utterance, devices: candidates, known: known)
        }
        guard let outcome else {
            if Task.isCancelled { return AssistantReply(kind: .info, text: "Cancelled.", source: Self.jevSource) }
            return jevFallback(JevCommandDecider.Unsure(reason: "it took too long", devices: [], device: nil, actions: [], missingValue: nil),
                               heard: heard, utterance: utterance, origin: origin, known: known, candidates: candidates, fallback: fallback)
        }
        switch outcome {
        case .accepted(let summary, let command, let deviceStrength, let actionStrength):
            guard let device = controller.device(id: summary.id) else {
                return AssistantReply(kind: .error, text: "Jev named a device I don't know.", source: Self.jevSource)
            }
            // Always confirmed first, whatever DeviceController's count threshold says.
            pendingChoice = nil
            pending = [CommandRequest(resolution: .single(device), command: command, origin: .model, confirmed: false)]
            let action = CommandPhrasing.action(command, target: CommandPhrasing.targetPhrase([summary], scope: nil))
            let measured = [deviceStrength, actionStrength].compactMap { $0 }.min().map { " (\(JevCommandDecider.percent($0)) sure)" } ?? ""
            return AssistantReply(kind: .needsConfirmation, text: "\(heard). Jev matched: \(action)\(measured). Go ahead?", source: Self.jevSource)
        case .unsure(let unsure):
            return jevFallback(unsure, heard: heard, utterance: utterance, origin: origin, known: known, candidates: candidates, fallback: fallback)
        }
    }

    private func jevFallback(_ unsure: JevCommandDecider.Unsure, heard: String, utterance: String, origin: CommandOrigin,
                             known: DeviceCommand?, candidates: [DeviceSummary], fallback: CommandResult?) -> AssistantReply {
        AppLog.assistant.info("jev failed open: \(unsure.reason, privacy: .public)")
        let lead = "\(Self.jevUnsureLead) (\(unsure.reason))"
        // A device was settled but not the action / value: ask about the action.
        if let device = unsure.device, known == nil {
            if let action = unsure.missingValue {
                return AssistantReply(kind: .ambiguous, text: "\(heard). \(lead) — to \(action.phrase) of \(device.name), say the value too (for example \u{201C}set \(device.name) to 50\u{201D}).",
                                      source: Self.jevSource)
            }
            if !unsure.actions.isEmpty {
                let options = CommandPhrasing.list(unsure.actions.map { "\($0.phrase) \(device.name)" }, conjunction: "or")
                return AssistantReply(kind: .ambiguous, text: "\(heard). \(lead) — did you mean \(options)?", source: Self.jevSource)
            }
        }
        // Devices Jev leaned to; for an ambiguous request, the parser's own candidates.
        var suggestions = unsure.devices
        if suggestions.isEmpty, let fallback, case .ambiguous(let options) = fallback.disposition { suggestions = options }
        if let known, !suggestions.isEmpty {
            if suggestions.count == 1, let device = controller.device(id: suggestions[0].id) {
                // One suggestion: still a proposal that waits for "yes".
                pending = [CommandRequest(resolution: .single(device), command: known, origin: .model, confirmed: false)]
                let action = CommandPhrasing.action(known, target: suggestions[0].name)
                return AssistantReply(kind: .needsConfirmation, text: "\(heard). \(lead) — did you mean: \(action)?", source: Self.jevSource)
            }
            // The user answers by name; the existing choice flow runs only what they pick.
            pendingChoice = (known, suggestions)
            let names = CommandPhrasing.list(suggestions.map(\.name), conjunction: "or")
            return AssistantReply(kind: .ambiguous, text: "\(heard). \(lead) — did you mean \(names)?", source: Self.jevSource)
        }
        if !suggestions.isEmpty {
            let names = CommandPhrasing.list(suggestions.map(\.name), conjunction: "or")
            return AssistantReply(kind: .ambiguous, text: "\(heard). \(lead) — did you mean \(names)? Say the device and what to do.", source: Self.jevSource)
        }
        if let fallback {
            return AssistantReply(kind: .error, text: "\(lead). \(fallback.spokenSummary)", result: fallback, source: Self.jevSource)
        }
        return AssistantReply(kind: .error, text: "\(Self.notUnderstoodText(utterance, origin: origin, note: "")) \(lead).", source: Self.jevSource)
    }

}

/// A planner error carried across the Deadline boundary (Error is not Sendable).
struct PlannerFailure: Error, @unchecked Sendable {
    let error: Error
    init(_ error: Error) { self.error = error }
    var localizedDescription: String { error.localizedDescription }
}

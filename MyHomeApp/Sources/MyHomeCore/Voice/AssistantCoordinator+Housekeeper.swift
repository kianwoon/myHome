// Routing with the housekeeper agent in place. The parser keeps only what
// must stay deterministic: "yes"/"no" for a pending confirmation, and the
// optional fast path (a parsed command that resolves to ONE controllable
// device, a state question, a single-device status). Everything else is the
// agent's turn; if it cannot be reached, the pre-agent flow answers and the
// reply says so.
import Foundation

extension AssistantCoordinator {
    // allow-hardcode: spoken UI copy.
    static let nothingPendingText = "Nothing is waiting for confirmation."
    static let nothingToCancelText = "Nothing to cancel."
    static let cancelledText = "Cancelled."
    static let confirmRefusedText = "Confirmation must come from you directly, not from a link or launch argument; nothing was changed."

    /// "yes" to a housekeeper plan: run it through the agent's own apply path,
    /// bounded by a deadline that scales with the number of devices.
    func runHousekeeperConfirmed(_ agent: HousekeeperAgent) async -> AssistantReply {
        let requests = pending
        pending = []
        let tools = agent.tools
        let seconds = timeouts.command(forDevices: tools.pendingDeviceCount)
        let results = await Deadline.run(seconds: seconds) { @MainActor in await tools.applyConfirmed() }
            ?? requests.map { Self.uncertainResult($0, controller: controller, reason: Self.tookTooLongText) }
        let text = results.map(\.spokenSummary).joined(separator: " ")
        return AssistantReply(kind: Self.kind(for: results), text: text, result: results.last, source: Self.housekeeperSource)
    }

    /// `.executed` only when something was actually sent; all failed → `.error`.
    static func kind(for results: [CommandResult]) -> AssistantReply.Kind {
        results.contains { $0.outcomes.contains { $0.status.wasSent } } ? .executed : .error
    }

    func handleWithHousekeeper(_ utterance: String, intent: ParsedIntent, origin: CommandOrigin, agent: HousekeeperAgent) async -> AssistantReply {
        switch intent {
        case .confirm:
            if !origin.canConfirm {
                // A link or launch argument can never say "yes" for the household.
                return AssistantReply(kind: .info, text: Self.confirmRefusedText, source: Self.grammarSource)
            }
            if hasPendingConfirmation, agent.tools.hasPendingConfirmation { return await runHousekeeperConfirmed(agent) }
            if let reply = await runPending() { return reply }
            // "yes" with no plan waiting answers the agent's open question, if any.
            guard agent.hasPendingQuestion else { return AssistantReply(kind: .info, text: Self.nothingPendingText, source: Self.grammarSource) }
        case .cancel:
            if hasPendingConfirmation || pendingChoice != nil { agent.tools.clearPendingConfirmation(); return dropPending() }
            // "no" may answer the agent's question; a bare cancel word withdraws it.
            guard agent.hasPendingQuestion else { return AssistantReply(kind: .info, text: Self.nothingToCancelText, source: Self.grammarSource) }
            if Self.isBareCancel(utterance, parser: parser) {
                agent.clearPendingQuestion()
                return AssistantReply(kind: .info, text: Self.cancelledText, source: Self.grammarSource)
            }
        default:
            break
        }
        // A new request supersedes anything still waiting for a yes.
        pending = []
        pendingChoice = nil
        if housekeeperFastPath, !agent.hasPendingQuestion, let reply = await fastPathReply(intent, origin: origin) {
            AppLog.assistant.info("fast path answered without the model")
            return reply
        }
        return await runHousekeeper(utterance, intent: intent, origin: origin, agent: agent)
    }

    /// "cancel" / "never mind" / "forget it" (not "no"/"nope", which can answer a question).
    static func isBareCancel(_ utterance: String, parser: VoiceCommandParser) -> Bool {
        let tokens = TextNormalizer.rawTokens(utterance).filter { !parser.vocabulary.stopWords.contains($0) }
        return !tokens.isEmpty && !tokens.contains { parser.grammar.answerNoWords.contains($0) }
    }

    /// The parser's deterministic answers; nil hands the turn to the agent.
    func fastPathReply(_ intent: ParsedIntent, origin: CommandOrigin) async -> AssistantReply? {
        switch intent {
        case .stateQuery(let query):
            // A question whose extra words match nothing ("… and at what level")
            // is not the parser's to answer: the agent reads it properly.
            let devices = controller.summaries()
            guard devices.contains(where: { DeviceQueryAnswerer.matches($0, query) }) else { return nil }
            return AssistantReply(kind: .status, text: DeviceQueryAnswerer.answer(query, devices: devices, listMax: stateQueryListMax),
                                  source: Self.grammarSource)
        case .status(let query):
            guard case .single(let device) = controller.resolve(query) else { return nil }
            return AssistantReply(kind: .status, text: CommandPhrasing.describe(controller.summary(for: device)) + ".", source: Self.grammarSource)
        case .command(let query, let command):
            var scoped = query
            scoped.preferControllable = true
            scoped.requiredCapability = command.capability
            guard case .single(let device) = controller.resolve(scoped), case .allowed = controller.check(command, on: device) else { return nil }
            let request = CommandRequest(resolution: .single(device), command: command, origin: origin, confirmed: true)
            guard let result = await boundedPerform(request) else { return timeoutReply() }
            return reply(for: result, source: Self.grammarSource)
        default:
            return nil
        }
    }

    func runHousekeeper(_ utterance: String, intent: ParsedIntent, origin: CommandOrigin, agent: HousekeeperAgent) async -> AssistantReply {
        let outcome = await agent.run(utterance, origin: origin)
        switch outcome {
        case .reply(let text):
            let acted = agent.tools.hasSideEffects
            // Something was attempted: executed only if at least one device took it.
            let kind: AssistantReply.Kind = acted ? Self.kind(for: agent.tools.executed) : .status
            return AssistantReply(kind: kind, text: text, result: agent.tools.executed.last, source: Self.housekeeperSource)
        case .ask(let question):
            return AssistantReply(kind: .ambiguous, text: question, source: Self.housekeeperSource)
        case .needsConfirmation(let requests, let text):
            pending = requests
            return AssistantReply(kind: .needsConfirmation, text: text, source: Self.housekeeperSource)
        case .failed(let reason, let sideEffects):
            if Task.isCancelled { return AssistantReply(kind: .info, text: Self.cancelledText, source: Self.housekeeperSource) }
            if sideEffects {
                // Changes already happened: never re-run the request elsewhere.
                let done = agent.tools.executed.map(\.spokenSummary).joined(separator: " ")
                return AssistantReply(kind: .error, text: "The housekeeper stopped after making changes (\(reason)). \(done)",
                                      result: agent.tools.executed.last, source: Self.housekeeperSource)
            }
            AppLog.assistant.error("housekeeper unavailable, falling back: \(reason, privacy: .public)")
            let fallback = await processWithoutHousekeeper(utterance, intent: intent, origin: origin, usePlanner: false)
            // allow-hardcode: spoken UI copy.
            return AssistantReply(kind: fallback.kind, text: "The housekeeper could not be reached (\(reason)), so the basic parser answered: \(fallback.text)",
                                  result: fallback.result, source: fallback.source)
        }
    }
}

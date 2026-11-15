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
        let seconds = commandDeadline(forDevices: tools.pendingDeviceCount)
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
        if housekeeperFastPath, !agent.hasPendingQuestion {
            if let reply = await compoundReply(utterance, origin: origin) {
                AppLog.assistant.info("fast path ran a multi-command sentence without the model")
                return reply
            }
            // A multi-command sentence the fast path cannot fully run goes to the
            // agent whole; the single-command fast path would drop the other clauses.
            if parser.splitCommands(utterance) == nil, let reply = await fastPathReply(intent, origin: origin) {
                AppLog.assistant.info("fast path answered without the model")
                return reply
            }
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

    /// "turn off the fan and open the curtain": every clause must resolve to ONE
    /// allowed device before any runs (else nil, nothing executed). Clauses on
    /// DIFFERENT devices run concurrently (capped like the controller's own
    /// parallelism); clauses on the same device run in the order spoken. One
    /// reply reports them all, in the order spoken.
    func compoundReply(_ utterance: String, origin: CommandOrigin) async -> AssistantReply? {
        guard let commands = parser.splitCommands(utterance) else { return nil }
        var requests: [CommandRequest] = []
        for (query, command) in commands {
            var scoped = query
            scoped.preferControllable = true
            scoped.requiredCapability = command.capability
            guard case .single(let device) = controller.resolve(scoped), case .allowed = controller.check(command, on: device) else { return nil }
            requests.append(CommandRequest(resolution: .single(device), command: command, origin: origin, confirmed: true))
        }
        pending = []
        pendingChoice = nil
        // Each clause has its own deadline: one slow device never starves the
        // others. A clause that times out is reported as uncertain.
        let results = await runClauses(requests)
        if Task.isCancelled { return timeoutReply() }
        let text = results.map(\.spokenSummary).joined(separator: " ")
        return AssistantReply(kind: Self.kind(for: results), text: text, result: results.last, source: Self.grammarSource)
    }

    /// Per-device lanes (clause order kept inside a lane), lanes run
    /// concurrently up to `parallelDevices`; results come back in clause order.
    func runClauses(_ requests: [CommandRequest]) async -> [CommandResult] {
        var lanes: [[Int]] = []
        var laneByDevice: [String: Int] = [:]
        for (index, request) in requests.enumerated() {
            let key = request.resolution.devices.map(\.id).joined(separator: ",")
            if let lane = laneByDevice[key] { lanes[lane].append(index) } else {
                laneByDevice[key] = lanes.count
                lanes.append([index])
            }
        }
        var results = [CommandResult?](repeating: nil, count: requests.count)
        let cap = max(controller.config.parallelDevices, 1)
        await withTaskGroup(of: [(Int, CommandResult)].self) { group in
            var pending = lanes.makeIterator()
            var running = 0
            while running < cap, let lane = pending.next() {
                group.addTask { @MainActor in await self.runLane(lane, requests) }
                running += 1
            }
            while let finished = await group.next() {
                for (index, result) in finished { results[index] = result }
                if let lane = pending.next() { group.addTask { @MainActor in await self.runLane(lane, requests) } }
            }
        }
        return results.enumerated().map { index, result in
            result ?? Self.uncertainResult(requests[index], controller: controller, reason: Self.tookTooLongText)
        }
    }

    private func runLane(_ lane: [Int], _ requests: [CommandRequest]) async -> [(Int, CommandResult)] {
        var done: [(Int, CommandResult)] = []
        for index in lane {
            if Task.isCancelled { break }
            let result = await boundedPerform(requests[index])
                ?? Self.uncertainResult(requests[index], controller: controller, reason: Self.tookTooLongText)
            done.append((index, result))
        }
        return done
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

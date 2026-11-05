import Foundation
import XCTest
@testable import MyHomeCore

/// Bridge that answers ok and records every request.
private final class RecordingBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String: Any]] = []
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return log }
    private func record(_ payload: [String: Any]) { lock.lock(); log.append(payload); lock.unlock() }
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        record(payload)
        return ["ok": true, "dps": payload["dps"] as Any]
    }
}

/// Scripted model: returns queued turns (or a computed one) and records what it saw.
@MainActor
private final class ScriptedTransport: AgentTransport {
    var unavailableReason: String?
    var toolWire: AgentToolWire = .native
    var requestTimeout: TimeInterval = 10
    var turns: [AgentTurn] = []
    var script: (([AgentMessage], [AgentToolDefinition]) -> AgentTurn)?
    var seen: [[AgentMessage]] = []
    var error: AgentTransportError?
    var hangs = false

    func complete(_ messages: [AgentMessage], tools: [AgentToolDefinition]) async throws -> AgentTurn {
        seen.append(messages)
        if hangs { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        if let error { throw error }
        if let script { return script(messages, tools) }
        guard !turns.isEmpty else { return AgentTurn(text: "Very good.") }
        return turns.removeFirst()
    }

    /// The content of every tool-result message the model was shown.
    var toolResults: [String] {
        seen.flatMap { $0 }.compactMap { if case .tool(_, _, let content) = $0 { return content }; return nil }
    }
}

private func call(_ name: String, _ arguments: [String: JSONValue] = [:], id: String = "call-1") -> AgentToolCall {
    AgentToolCall(id: id, name: name, arguments: arguments)
}

private func handles(_ names: [String]) -> JSONValue { .array(names.map(JSONValue.string)) }

@MainActor
final class HousekeeperAgentTests: XCTestCase {
    private var bridge: RecordingBridge!
    private var store: DeviceStore!
    private var controller: DeviceController!
    private var transport: ScriptedTransport!
    private var notes: HouseholdNotes!
    private var agent: HousekeeperAgent!
    private var assistant: AssistantCoordinator!

    // The study: a ceiling fan (off), a smart plug named like a light (no address),
    // six Briturn lights in three groups (four lit), plus a living room and a socket.
    private let fan = ControlFixtures.device("bf00000000000to2l", name: "Study Fan", category: "fs", room: "Study room", spec: ControlFixtures.fanSpec)
    private let plug = ControlFixtures.device("bf0000000000000qgab", name: "Study light", category: "cz", room: "Study room", ip: "")
    private let computer = ControlFixtures.device("bf0000000000009ppe", name: "Main computer", category: "cz", room: "Study room")
    private let livingFan = ControlFixtures.device("bf000000000000xf2y", name: "Living Fan", category: "fs", room: "Living room", spec: ControlFixtures.fanSpec)
    private let lightIDs = ["8e6d": "study room Front", "931d": "study room Front", "84f1": "study room middle", "88b3": "study room middle",
                            "8911": "study room Back", "89e3": "study room Back", "90d9": "living side", "8641": "living side"]
    private let litTails = ["8e6d", "931d", "84f1", "8911", "90d9", "8641"]
    private let offline = ControlFixtures.device("briturn-aabbccdd0ff1", name: "Hall Lamp", category: "briturn", group: "hall", ip: "", online: false)

    private var lights: [Device] {
        lightIDs.keys.sorted().map { tail in
            ControlFixtures.device("briturn-aabbccdd\(tail)", name: "Briturn Light \(tail)", category: "briturn", group: lightIDs[tail])
        }
    }

    private func lit(_ on: Bool) -> DeviceStore.BriturnState {
        DeviceStore.BriturnState(on: on, rawPower: on ? 0x23 : 0x24, mode: 97, r: 255, g: 255, b: 255, w: 0)
    }

    override func setUp() {
        super.setUp()
        bridge = RecordingBridge()
        store = DeviceStore(bridge: bridge, defaults: UserDefaults(suiteName: "HousekeeperAgentTests-\(UUID())")!)
        store.setRosterForTest([fan, plug, computer, livingFan, offline] + lights)
        store.applyStatus(fan.id, decoded: ["1": .bool(false), "3": .number(2)])
        store.applyStatus(livingFan.id, decoded: ["1": .bool(true), "3": .number(3)])
        store.applyStatus(computer.id, decoded: ["1": .bool(true)])
        for light in lights { store.setBriturnStatus(light.id, lit(litTails.contains { light.id.hasSuffix($0) })) }
        // Threshold 2: the controller alone would ask for any two devices.
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 2))
        // Lights answer the read-back with what the last write asked for.
        let bridge = self.bridge!
        let store = self.store!
        store.briturnLANReadHook = { device in
            guard let prev = store.briturnStatus[device.id] else { return nil }
            guard let last = bridge.requests.last(where: { $0["cmd"] as? String == "briturnset" && $0["id"] as? String == device.id }) else { return prev }
            let on = last["on"] as? Bool ?? prev.on
            let channel = (last["brightness"] as? Int).map { Int((Double($0) * 2.55).rounded()) } ?? prev.r
            return DeviceStore.BriturnState(on: on, rawPower: on ? 0x23 : 0x24, mode: prev.mode, r: channel, g: channel, b: channel, w: 0)
        }
        transport = ScriptedTransport()
        notes = HouseholdNotes(fileURL: nil)
        let tools = HousekeeperTools(controller: controller, notes: notes)
        agent = HousekeeperAgent(controller: controller, tools: tools, transport: transport, limits: HousekeeperLimits(turnTimeout: 20, requestTimeout: 10))
        assistant = AssistantCoordinator(controller: controller, planner: nil)
        assistant.housekeeper = agent
        assistant.timeouts = AssistantTimeouts(planner: 5, command: 5)
    }

    private func level(_ tail: String) -> Int? {
        controller.summary(for: lights.first { $0.id.hasSuffix(tail) }!).levelPercent
    }

    // MARK: Acceptance

    func testDimTheStudyRoomLightJustHappensWithoutAQuestion() async {
        transport.turns = [
            AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["light-8e6d", "light-931d", "light-84f1", "light-8911"]),
                                                       "action": .string("level"), "value": .number(50)])]),
            AgentTurn(text: "Very good. The four study lights that were lit are now at half."),
        ]
        let reply = await assistant.handle("dim the study room light to 50%", origin: .text)
        XCTAssertEqual(reply.kind, .executed, reply.text)
        XCTAssertEqual(reply.source, AssistantCoordinator.housekeeperSource)
        XCTAssertFalse(reply.text.contains("?"), "no question, no confirmation: \(reply.text)")
        XCTAssertFalse(reply.text.localizedCaseInsensitiveContains("go ahead"))
        XCTAssertFalse(assistant.hasPendingConfirmation)
        XCTAssertNil(assistant.pendingChoice)
        // Every lit light is written on its own transport and read back; nothing else is touched.
        XCTAssertTrue(bridge.requests.filter { $0["cmd"] as? String == "briturnsetgroup" }.isEmpty, "no group write")
        let singleWrites = bridge.requests.filter { $0["cmd"] as? String == "briturnset" }
        XCTAssertEqual(Set(singleWrites.compactMap { ($0["id"] as? String)?.suffix(4) }.map(String.init)), ["8e6d", "931d", "84f1", "8911"])
        XCTAssertTrue(singleWrites.allSatisfy { $0["brightness"] as? Int == 50 })
        XCTAssertEqual(singleWrites.count, 4)
        XCTAssertEqual(level("8e6d"), 50, "the read-back painted the new level")
        for tail in ["88b3", "89e3"] { XCTAssertEqual(controller.summary(for: lights.first { $0.id.hasSuffix(tail) }!).isOn, false, "off lights stay off") }
        XCTAssertEqual(level("90d9"), 100, "the living room is untouched")
        XCTAssertEqual(store.power(for: fan), false)
        XCTAssertTrue(transport.toolResults.first?.contains("4 of 4 confirmed") == true, transport.toolResults.first ?? "")
        XCTAssertTrue(transport.toolResults.first?.contains("CONFIRMED by read-back") == true)
    }

    func testSystemPromptCarriesLiveStateHandlesAndDerivedRooms() {
        let prompt = agent.systemPrompt()
        XCTAssertTrue(prompt.contains("light-8e6d | Briturn Light 8e6d | Study room | study room Front | light | on 100% | wifi | "), prompt)
        XCTAssertTrue(prompt.contains("light-88b3 | Briturn Light 88b3 | Study room | study room middle | light | off | wifi |"), prompt)
        XCTAssertTrue(prompt.contains("fan-to2l | Study Fan | Study room | - | fan | off | wifi | fan_speed(gear), level(speed %), mode, power_on/power_off"), prompt)
        XCTAssertTrue(prompt.contains("plug-qgab | Study light | Study room | - | plug (smart socket, power only) | offline | NOT CONTROLLABLE (no control path) | -"), prompt)
        XCTAssertTrue(prompt.contains("| on 100% | wifi | color_temperature(0 warm-100 cool), level(brightness %), power_on/power_off"), "no colour action exists, so none is advertised")
        XCTAssertTrue(prompt.contains("light-0ff1 | Hall Lamp | hall | hall | light | offline |"), prompt)
        XCTAssertTrue(prompt.contains("Household notes:\n<household_notes>\n(none)"))
        XCTAssertTrue(prompt.contains("head housekeeper"))
    }

    func testCountIsComputedByCodeNotTheModel() async {
        assistant.housekeeperFastPath = false
        transport.turns = [AgentTurn(text: "", toolCalls: [call("count", ["kind": .string("light"), "state": .string("on")])]),
                           AgentTurn(text: "Six lights are on.")]
        let reply = await assistant.handle("how many lights are on?", origin: .text)
        XCTAssertEqual(reply.kind, .status)
        XCTAssertEqual(reply.text, "Six lights are on.")
        let result = transport.toolResults.first ?? ""
        XCTAssertTrue(result.contains("\"count\":6"), result)
        XCTAssertTrue(result.contains("\"off\":2"), result)
        XCTAssertTrue(result.contains("\"offline\":1"), result)
    }

    func testFastPathAnswersStateQuestionsAndSingleDeviceCommandsWithoutTheModel() async {
        let count = await assistant.handle("how many lights are on?", origin: .text)
        XCTAssertEqual(count.source, AssistantCoordinator.grammarSource)
        XCTAssertTrue(count.text.hasPrefix("6 of 8 lights"), count.text)
        let fanOn = await assistant.handle("turn on the study fan", origin: .voice)
        XCTAssertEqual(fanOn.kind, .executed)
        XCTAssertEqual(fanOn.text, "Turned on Study Fan.")
        XCTAssertTrue(transport.seen.isEmpty, "the model is never consulted on the fast path")
        transport.turns = [AgentTurn(text: "Four study lights are lit, all at full.")]
        let odd = await assistant.handle("which study room lights are on and at what level?", origin: .text)
        XCTAssertEqual(odd.source, AssistantCoordinator.housekeeperSource, "a state question whose words match no device goes to the agent: \(odd.text)")
        assistant.housekeeperFastPath = false
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["fan-to2l"]), "action": .string("power_off")])]),
                           AgentTurn(text: "The study fan is off.")]
        let fanOff = await assistant.handle("turn off the study fan", origin: .text)
        XCTAssertEqual(fanOff.source, AssistantCoordinator.housekeeperSource)
        XCTAssertEqual(transport.seen.count, 3, "one model turn for the odd question, two for the fan")
        XCTAssertEqual(store.power(for: fan), false)
    }

    func testSpeedOnASleepingFanPowersItOnFirst() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["fan-to2l"]), "action": .string("fan_speed"), "value": .number(3)])]),
                           AgentTurn(text: "The study fan is running at a moderate speed.")]
        let reply = await assistant.handle("it's stuffy in the study", origin: .text)
        XCTAssertEqual(reply.kind, .executed, reply.text)
        XCTAssertEqual(store.power(for: fan), true, "a Tuya fan stores a gear while off; it must be switched on")
        XCTAssertEqual(store.dps(for: fan)["3"], .number(3))
        let result = transport.toolResults.first ?? ""
        XCTAssertTrue(result.contains("(was off: turned on first)"), result)
        XCTAssertTrue(result.contains("2 of 2 confirmed"), result)
        let sets = bridge.requests.compactMap { $0["dps"] as? [String: Any] }
        XCTAssertEqual(sets.map { $0.keys.sorted() }, [["1"], ["3"]], "power first, then the gear: \(sets)")
        // Undo puts the fan back to off (it was off before).
        transport.turns = [AgentTurn(text: "", toolCalls: [call("undo_last")]), AgentTurn(text: "Fan off again.")]
        _ = await assistant.handle("undo that", origin: .text)
        XCTAssertEqual(store.power(for: fan), false)
    }

    func testRefusedDeviceIsReportedEvenWhenTheModelForgets() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["light-0ff1", "light-90d9"]), "action": .string("level"), "value": .string("30%")])]),
                           AgentTurn(text: "Done.")]
        let reply = await assistant.handle("dim the hall and living lights", origin: .text)
        XCTAssertEqual(reply.kind, .executed)
        XCTAssertTrue(reply.text.contains("Not done: Hall Lamp has no control path"), reply.text)
        XCTAssertTrue(transport.toolResults.first?.contains("REFUSED") == true)
        XCTAssertEqual(bridge.requests.last?["brightness"] as? Int, 30)
        XCTAssertEqual((bridge.requests.last?["id"] as? String)?.hasSuffix("90d9"), true)
    }

    func testSocketAsksOnceAndYesRunsIt() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["plug-9ppe"]), "action": .string("power_off")])])]
        let ask = await assistant.handle("cut the power to the main computer", origin: .text)
        XCTAssertEqual(ask.kind, .needsConfirmation)
        XCTAssertTrue(ask.text.hasSuffix("Go ahead?"), ask.text)
        XCTAssertTrue(ask.text.contains("Turn off Main computer"), ask.text)
        XCTAssertEqual(store.power(for: computer), true, "nothing runs before the yes")
        let done = await assistant.handle("yes", origin: .text)
        XCTAssertEqual(done.kind, .executed)
        XCTAssertEqual(store.power(for: computer), false)
        XCTAssertFalse(assistant.hasPendingConfirmation)
    }

    func testSweepAcrossRoomsAsksButARoomRunsAtOnce() async {
        agent.tools.policy = HousekeeperPolicy(maxDevicesAcrossRoomsWithoutConfirm: 4)
        let study = handles(["light-8e6d", "light-931d", "light-84f1", "light-88b3", "light-8911", "light-89e3"])
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": study, "action": .string("power_off")])]), AgentTurn(text: "Lights out in the study.")]
        let room = await assistant.handle("study lights off please", origin: .text)
        XCTAssertEqual(room.kind, .executed, room.text)
        XCTAssertFalse(assistant.hasPendingConfirmation)
        let everywhere = handles(["light-8e6d", "light-931d", "light-84f1", "light-88b3", "light-8911", "light-89e3", "light-90d9", "light-8641"])
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": everywhere, "action": .string("power_on")])])]
        let sweep = await assistant.handle("all lights on", origin: .text)
        XCTAssertEqual(sweep.kind, .needsConfirmation, sweep.text)
        XCTAssertTrue(sweep.text.contains("across 2 rooms"), sweep.text)
    }

    func testIterationCapFailsOpenToTheParserWhenNothingRan() async {
        agent.limits.maxIterations = 2
        transport.script = { _, _ in AgentTurn(text: "", toolCalls: [call("get_state", ["handles": handles(["fan-to2l"])])]) }
        let reply = await assistant.handle("do the thing", origin: .text)
        XCTAssertEqual(transport.seen.count, 2)
        XCTAssertTrue(reply.text.hasPrefix("The housekeeper could not be reached (the housekeeper did not finish within 2 steps)"), reply.text)
        XCTAssertTrue(reply.text.contains("couldn't match it to a command"), reply.text)
    }

    func testFailureAfterChangesNeverRetriesElsewhere() async {
        agent.limits.maxIterations = 1
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["fan-to2l"]), "action": .string("power_on")])])]
        let reply = await assistant.handle("fan on in the study", origin: .text)
        XCTAssertEqual(reply.kind, .error)
        XCTAssertTrue(reply.text.contains("stopped after making changes"), reply.text)
        XCTAssertTrue(reply.text.contains("Turned on Study Fan"), reply.text)
        XCTAssertEqual(store.power(for: fan), true)
    }

    func testUndoLastRestoresThePreviousLevels() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["light-8e6d", "light-931d"]), "action": .string("level"), "value": .number(40)])]),
                           AgentTurn(text: "Done.")]
        _ = await assistant.handle("front study lights to 40", origin: .text)
        XCTAssertEqual(level("8e6d"), 40)
        transport.turns = [AgentTurn(text: "", toolCalls: [call("undo_last")]), AgentTurn(text: "Back as they were.")]
        let reply = await assistant.handle("undo that", origin: .text)
        XCTAssertEqual(reply.text, "Back as they were.")
        let restored = bridge.requests.filter { $0["cmd"] as? String == "briturnset" }.suffix(2)
        XCTAssertEqual(Set(restored.compactMap { ($0["id"] as? String)?.suffix(4) }.map(String.init)), ["8e6d", "931d"])
        XCTAssertTrue(restored.allSatisfy { $0["brightness"] as? Int == 100 }, "\(restored)")
        // Undo is itself undoable: the restore became the last change.
        transport.turns = [AgentTurn(text: "", toolCalls: [call("undo_last")]), AgentTurn(text: "Dimmed again.")]
        _ = await assistant.handle("undo again", origin: .text)
        XCTAssertEqual(bridge.requests.last?["brightness"] as? Int, 40)
        let fresh = HousekeeperTools(controller: controller, notes: notes)
        if case .error(let text) = await fresh.execute(call("undo_last")) { XCTAssertEqual(text, "nothing to undo") } else { XCTFail("nothing recorded yet") }
    }

    func testAskUserEndsTheTurnAndTheNextUtteranceContinuesIt() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("ask_user", ["question": .string("Which room do you mean?")])])]
        let ask = await assistant.handle("make it cosy", origin: .text)
        XCTAssertEqual(ask.kind, .ambiguous)
        XCTAssertEqual(ask.text, "Which room do you mean?")
        XCTAssertTrue(agent.hasPendingQuestion)
        transport.turns = [AgentTurn(text: "Very good, the study it is.")]
        let answer = await assistant.handle("the study", origin: .text)
        XCTAssertEqual(answer.text, "Very good, the study it is.")
        XCTAssertFalse(agent.hasPendingQuestion)
        let shown = transport.seen.last ?? []
        XCTAssertEqual(shown.dropFirst().map { message -> String in
            switch message {
            case .user(let text): return "user:\(text)"
            case .assistant(let text, _, _): return "assistant:\(text)"
            default: return "?"
            }
        }, ["user:make it cosy", "assistant:Which room do you mean?", "user:the study"])
    }

    func testYesAndNoAnswerAnOpenQuestionButCancelWithdrawsIt() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("ask_user", ["question": .string("Shall I turn on the fan too?")])])]
        _ = await assistant.handle("it is warm", origin: .text)
        transport.turns = [AgentTurn(text: "The fan is on.")]
        let yes = await assistant.handle("yes", origin: .text)
        XCTAssertEqual(yes.text, "The fan is on.", "a bare yes with no plan pending answers the question")
        transport.turns = [AgentTurn(text: "", toolCalls: [call("ask_user", ["question": .string("And the lights?")])])]
        _ = await assistant.handle("anything else?", origin: .text)
        let cancelled = await assistant.handle("never mind", origin: .text)
        XCTAssertEqual(cancelled.text, "Cancelled.")
        XCTAssertFalse(agent.hasPendingQuestion)
    }

    func testFollowUpSeesThePreviousTurnAndItsActions() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["light-8e6d"]), "action": .string("level"), "value": .number(50)])]),
                           AgentTurn(text: "Half, as asked.")]
        _ = await assistant.handle("dim the front study light to 50%", origin: .text)
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["light-8e6d"]), "action": .string("level"), "value": .number(30)])]),
                           AgentTurn(text: "A little lower.")]
        let reply = await assistant.handle("a bit lower", origin: .text)
        XCTAssertEqual(reply.source, AssistantCoordinator.housekeeperSource, "\"lower\" must not run as a curtain command: \(reply.text)")
        XCTAssertEqual(bridge.requests.last?["brightness"] as? Int, 30)
        let remembered = transport.seen.last?.compactMap { message -> String? in
            if case .assistant(let text, _, _) = message { return text }
            return nil
        } ?? []
        XCTAssertTrue(remembered.contains { $0.contains("Half, as asked.") && $0.contains("(did: Set  to 50% → light-8e6d confirmed)") }, "\(remembered)")
    }

    func testMemoryExpiresAfterTheIdleWindow() async {
        var now = Date()
        agent.clock = { now }
        agent.limits.memoryIdle = 60
        transport.turns = [AgentTurn(text: "Noted.")]
        _ = await assistant.handle("hello", origin: .text)
        XCTAssertEqual(agent.memory.turns.count, 1)
        now = now.addingTimeInterval(61)
        transport.turns = [AgentTurn(text: "Again.")]
        _ = await assistant.handle("hello again", origin: .text)
        XCTAssertEqual(agent.memory.turns.count, 1, "the stale turn was dropped before the new one")
        XCTAssertEqual(agent.memory.turns.first?.user, "hello again")
    }

    func testTransportFailureFallsBackToTheParserAndSaysSo() async {
        transport.error = .failed("the provider did not answer in time")
        let reply = await assistant.handle("turn on the study room light", origin: .text)
        XCTAssertTrue(reply.text.hasPrefix("The housekeeper could not be reached (the provider did not answer in time), so the basic parser answered: "), reply.text)
        XCTAssertEqual(reply.source, AssistantCoordinator.grammarSource)
    }

    func testUnavailableTransportLeavesTheOldFlowInCharge() async {
        transport.unavailableReason = "add an API key in Settings → Assistant"
        let reply = await assistant.handle("turn on the study fan", origin: .text)
        XCTAssertEqual(reply.text, "Turned on Study Fan.")
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testCancelAbandonsAHangingModel() async {
        transport.hangs = true
        let pending = Task { await assistant.handle("make it cosy in the study", origin: .voice) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(assistant.isBusy)
        assistant.cancelActive()
        let reply = await pending.value
        XCTAssertEqual(reply.text, "Cancelled.")
        XCTAssertFalse(assistant.isBusy)
    }

    func testRememberOnlyWritesWhatTheModelAsksAndTheNextPromptShowsIt() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("remember", ["note": .string("the desk lamp is the one by the window")])]),
                           AgentTurn(text: "Noted.")]
        _ = await assistant.handle("remember the desk lamp is the one by the window", origin: .text)
        XCTAssertEqual(notes.notes.map(\.text), ["the desk lamp is the one by the window"])
        XCTAssertTrue(agent.systemPrompt().contains("Household notes:\n<household_notes>\n- [\(notes.notes[0].id.prefix(8))] the desk lamp is the one by the window"))
        transport.turns = [AgentTurn(text: "", toolCalls: [call("forget", ["id": .string(String(notes.notes[0].id.prefix(8)))])]), AgentTurn(text: "Forgotten.")]
        _ = await assistant.handle("please forget the note about the desk lamp", origin: .text)
        XCTAssertTrue(notes.notes.isEmpty)
    }

    func testReplyEndingInAQuestionMarkBecomesAnOpenQuestion() async {
        transport.turns = [AgentTurn(text: "Did you mean the study or the living room?")]
        let reply = await assistant.handle("dim the lights", origin: .text)
        XCTAssertEqual(reply.kind, .ambiguous)
        XCTAssertTrue(agent.hasPendingQuestion)
    }

    // MARK: Tools

    func testToolArgumentsAreValidatedAndCoerced() async {
        let tools = agent.tools
        tools.beginTurn()
        if case .error(let text) = await tools.execute(call("set", ["handles": handles(["ghost"]), "action": .string("level"), "value": .number(10)])) {
            XCTAssertTrue(text.contains("unknown handles: ghost"), text)
        } else { XCTFail("unknown handles must be an error") }
        if case .error(let text) = await tools.execute(call("set", ["handles": handles(["fan-to2l"]), "action": .string("explode")])) {
            XCTAssertTrue(text.contains("action must be one of: power_on, power_off, level"), text)
        } else { XCTFail("unknown actions must be an error") }
        if case .error(let text) = await tools.execute(call("set", ["handles": handles(["fan-to2l"]), "action": .string("level"), "value": .string("lots")])) {
            XCTAssertTrue(text.contains("level needs an integer value 0-100"), text)
        } else { XCTFail("bad values must be an error") }
        if case .error(let text) = await tools.execute(call("teleport")) {
            XCTAssertTrue(text.contains("unknown tool teleport"), text)
        } else { XCTFail("unknown tools must be an error") }
        // A single comma-separated string and a "50%" value are accepted.
        let outcome = await tools.execute(call("set", ["handles": .string("light-8e6d, LIGHT-931D"), "action": .string("level"), "value": .string("50%")]))
        if case .result(let text) = outcome { XCTAssertTrue(text.contains("2 of 2 confirmed"), text) } else { XCTFail("\(outcome)") }
        XCTAssertEqual(level("8e6d"), 50)
        if case .result(let text) = await tools.execute(call("get_state", ["handles": handles(["fan-to2l", "nope"])])) {
            XCTAssertTrue(text.contains("fan-to2l | Study Fan"), text)
            XCTAssertTrue(text.contains("unknown handles ignored: nope"), text)
        } else { XCTFail("get_state with one good handle must answer") }
        if case .result(let text) = await tools.execute(call("list_devices", ["room": .string("study"), "kind": .string("light"), "state": .string("off")])) {
            XCTAssertTrue(text.contains("light-88b3") && text.contains("light-89e3") && !text.contains("light-8e6d"), text)
        } else { XCTFail("list_devices must answer") }
        if case .result(let text) = await tools.execute(call("now")) {
            XCTAssertTrue(text.contains("\"part_of_day\""), text)
        } else { XCTFail("now must answer") }
    }

    func testPolicyKindsAndRoomSpan() {
        let handlesMap = DeviceHandles(devices: controller.summaries())
        let policy = HousekeeperPolicy()
        let study = controller.summaries().filter { $0.kind == .light && handlesMap.room(for: $0) == "Study room" }
        XCTAssertEqual(study.count, 6)
        XCTAssertNil(policy.confirmationReason(for: study, command: .level(50), handles: handlesMap))
        XCTAssertNotNil(policy.confirmationReason(for: [controller.summary(for: computer)], command: .power(false), handles: handlesMap))
        let everything = controller.summaries().filter { $0.kind == .light }
        XCTAssertEqual(policy.confirmationReason(for: everything, command: .power(false), handles: handlesMap), "this touches 9 devices across 3 rooms")
        XCTAssertNil(policy.confirmationReason(for: Array(everything.prefix(8)), command: .power(false), handles: handlesMap), "up to 8 across rooms runs")
    }

    func testHandlesAreStableUniqueAndRoomsAreDerivedFromGroups() {
        let first = DeviceHandles(devices: controller.summaries())
        let again = DeviceHandles(devices: controller.summaries().reversed())
        XCTAssertEqual(first.handle(for: fan.id), "fan-to2l")
        XCTAssertEqual(again.handle(for: fan.id), "fan-to2l", "handles come from ids, not from order")
        XCTAssertEqual(first.handle(for: plug.id), "plug-qgab")
        XCTAssertEqual(Set(controller.summaries().compactMap { first.handle(for: $0.id) }).count, controller.summaries().count)
        XCTAssertEqual(first.room(for: controller.summary(for: lights[0])), "Study room")
        XCTAssertEqual(first.room(for: controller.summary(for: lights.first { $0.group == "living side" }!)), "Living room")
        XCTAssertEqual(first.room(for: controller.summary(for: offline)), "hall", "an unknown group is its own area")
        XCTAssertEqual(first.device(for: " LIGHT-8E6D ")?.id, "briturn-aabbccdd8e6d")
        let twins = [DeviceSummary(id: "aaa1234", name: "A", room: "", group: nil, kind: .light, capabilities: [], reachability: .wifi, isControllable: true, isOn: nil, levelPercent: nil),
                     DeviceSummary(id: "bbb1234", name: "B", room: "", group: nil, kind: .light, capabilities: [], reachability: .wifi, isControllable: true, isOn: nil, levelPercent: nil)]
        let collide = DeviceHandles(devices: twins)
        XCTAssertEqual(collide.handle(for: "aaa1234"), "light-1234")
        XCTAssertEqual(collide.handle(for: "bbb1234"), "light-b1234")
    }

    func testHouseholdNotesPersistToTheFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = HouseholdNotes(fileURL: url)
        let note = first.add("  no fans after midnight  ")
        XCTAssertEqual(note?.text, "no fans after midnight")
        XCTAssertNil(first.add("   "))
        XCTAssertTrue(first.update(id: note!.id, text: "no fans after 1am"))
        let second = HouseholdNotes(fileURL: url)
        XCTAssertEqual(second.notes.map(\.text), ["no fans after 1am"])
        XCTAssertEqual(second.note(matching: String(note!.id.prefix(8)))?.id, note!.id)
        XCTAssertTrue(second.remove(id: note!.id))
        XCTAssertFalse(second.remove(id: note!.id))
        XCTAssertEqual(HouseholdNotes(fileURL: url).notes.count, 0)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes?[.posixPermissions] as? Int), 0o600)
    }

    func testLastReplyRecordRoundTrips() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("last-reply-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var trace = AgentTrace(utterance: "dim", origin: "text", startedAt: Date())
        trace.record(call("set", ["handles": handles(["light-8e6d"])]), result: "done", milliseconds: 12)
        trace.outcome = "reply"
        let record = LastReplyRecord(timestamp: Date(), utterance: "dim", origin: "text", kind: "executed", source: "housekeeper", text: "Very good.", trace: trace)
        XCTAssertTrue(LastReplyStore.write(record, to: url))
        let back = LastReplyStore.read(from: url)
        XCTAssertEqual(back?.text, "Very good.")
        XCTAssertEqual(back?.trace?.toolCalls.first?.name, "set")
        XCTAssertEqual(back?.trace?.toolCalls.first?.arguments, "{\"handles\":[\"light-8e6d\"]}")
    }
}

// MARK: - Review regressions (status reporting, confirmation origin, deadlines)

extension HousekeeperAgentTests {
    func testNamingTheDeviceInTheReplyDoesNotHideItsFailure() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["light-0ff1"]), "action": .string("power_off")])]),
                           AgentTurn(text: "The Hall Lamp is off.")]
        let reply = await assistant.handle("turn off the hall lamp", origin: .text)
        XCTAssertTrue(reply.text.contains("Not done: Hall Lamp"), reply.text)
        XCTAssertEqual(reply.kind, .error, "nothing was sent: not .executed")
    }

    func testFailedSetThenConfirmationInOneTurnReportsTheFailure() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["light-0ff1"]), "action": .string("power_off")], id: "c1")]),
                           AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["plug-9ppe"]), "action": .string("power_off")], id: "c2")])]
        let ask = await assistant.handle("hall lamp and computer off", origin: .text)
        XCTAssertEqual(ask.kind, .needsConfirmation)
        XCTAssertTrue(ask.text.contains("Not done: Hall Lamp"), ask.text)
        XCTAssertTrue(ask.text.hasSuffix("Go ahead?"), ask.text)
    }

    func testConfirmationFromURLOrDiagnosticOriginIsRefused() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["plug-9ppe"]), "action": .string("power_off")])])]
        _ = await assistant.handle("cut the power to the main computer", origin: .url)
        for origin in [CommandOrigin.url, .diagnostic] {
            let refused = await assistant.handle("yes", origin: origin)
            XCTAssertEqual(refused.kind, .info, refused.text)
            XCTAssertEqual(store.power(for: computer), true, "a link can never say yes")
            XCTAssertTrue(assistant.hasPendingConfirmation)
        }
        let done = await assistant.handle("yes", origin: .text)
        XCTAssertEqual(done.kind, .executed, done.text)
        XCTAssertEqual(store.power(for: computer), false)
    }

    func testConfirmedSetRunsThroughApplySoUndoRevertsIt() async {
        transport.turns = [AgentTurn(text: "", toolCalls: [call("set", ["handles": handles(["plug-9ppe"]), "action": .string("power_off")])])]
        _ = await assistant.handle("cut the power to the main computer", origin: .text)
        _ = await assistant.handle("yes", origin: .text)
        XCTAssertEqual(store.power(for: computer), false)
        XCTAssertFalse(agent.tools.executed.isEmpty, "the confirmed write is recorded")
        transport.turns = [AgentTurn(text: "", toolCalls: [call("undo_last")]), AgentTurn(text: "Restored.")]
        _ = await assistant.handle("undo that", origin: .text)
        XCTAssertEqual(store.power(for: computer), true, "undo reverts the confirmed set, not an older one")
    }

    func testDiagnosticSayIsOffUnlessEnabledOrEnvironment() {
        let defaults = UserDefaults(suiteName: "say-\(UUID())")!
        XCTAssertFalse(AppSettings.diagnosticSayAllowed(defaults: defaults, environment: [:]))
        XCTAssertTrue(AppSettings.diagnosticSayAllowed(defaults: defaults, environment: [AppSettings.diagnosticsEnvironmentVariable: "1"]))
        defaults.set(true, forKey: AppSettings.assistantSayURLEnabledKey)
        XCTAssertTrue(AppSettings.diagnosticSayAllowed(defaults: defaults, environment: [:]))
        XCTAssertFalse(CommandOrigin.url.canConfirm)
        XCTAssertFalse(CommandOrigin.diagnostic.canConfirm)
        XCTAssertTrue(CommandOrigin.text.canConfirm)
    }

    func testCommandDeadlineScalesWithDeviceCount() {
        let timeouts = AssistantTimeouts(planner: 5, command: 15, perDevice: 8)
        XCTAssertEqual(timeouts.command(forDevices: 1), 15)
        XCTAssertEqual(timeouts.command(forDevices: 4), 39)
    }

    func testRunPendingKeepsOutcomesWhenOneStepIsTooSlow() async {
        // Three stale lights whose read-back never returns, then a socket.
        let slow = lights.filter { ["8e6d", "84f1", "89e3"].contains(where: $0.id.hasSuffix) }
        store.briturnLANReadHook = { _ in try? await Task.sleep(nanoseconds: 60_000_000_000); return nil }
        assistant.timeouts = AssistantTimeouts(planner: 5, command: 0.2, perDevice: 0.05)
        assistant.pending = [CommandRequest(resolution: .set(slow, scope: .room("Study room")), command: .power(false), origin: .text),
                             CommandRequest(resolution: .single(computer), command: .power(false), origin: .text)]
        let reply = await assistant.confirmPending()
        XCTAssertNotNil(reply)
        XCTAssertFalse(reply?.text.contains("That took too long") ?? true, "outcomes are reported per device, not one blanket timeout")
        XCTAssertTrue(reply?.text.contains("not attempted") ?? false, reply?.text ?? "")
        XCTAssertEqual(store.power(for: computer), true, "the step after the slow one is not run")
    }
}

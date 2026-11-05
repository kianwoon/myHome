import Foundation
import XCTest
@testable import MyHomeCore

private final class EchoBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        ["ok": true, "dps": payload["dps"] as Any]
    }
}

/// Scripted Level-2 planner: returns a fixed plan, records what it was asked.
@MainActor
private final class ScriptedPlanner: NaturalLanguagePlanner {
    var isAvailable = true
    var unavailableReason: String? { isAvailable ? nil : "scripted off" }
    var plan = ProposedPlan(steps: [], summary: "")
    var error: PlannerError?
    var asked: [String] = []
    var seenDevices = 0
    var hangs = false

    func plan(_ utterance: String, devices: [DeviceSummary]) async throws -> ProposedPlan {
        asked.append(utterance)
        seenDevices = devices.count
        if hangs { while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } }
        if let error { throw error }
        return plan
    }
}

@MainActor
final class AssistantCoordinatorTests: XCTestCase {
    private var store: DeviceStore!
    private var controller: DeviceController!
    private var planner: ScriptedPlanner!
    private var assistant: AssistantCoordinator!

    private let fan = ControlFixtures.device("fan-study", name: "Study Fan", category: "fs", room: "Study", spec: ControlFixtures.fanSpec)
    private let lamp = ControlFixtures.device("lamp-desk", name: "Desk Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let lamp2 = ControlFixtures.device("lamp-floor", name: "Floor Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)

    override func setUp() {
        super.setUp()
        store = DeviceStore(bridge: EchoBridge(), defaults: UserDefaults(suiteName: "AssistantCoordinatorTests-\(UUID())")!)
        store.setRosterForTest([fan, lamp, lamp2])
        store.applyStatus(fan.id, decoded: ["1": .bool(false), "3": .number(2)])
        store.applyStatus(lamp.id, decoded: ["1": .bool(false), "2": .number(300)])
        store.applyStatus(lamp2.id, decoded: ["1": .bool(false), "2": .number(300)])
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 2))
        planner = ScriptedPlanner()
        assistant = AssistantCoordinator(controller: controller, planner: planner)
    }

    func testDirectCommandRunsWithoutTheModel() async {
        let reply = await assistant.handle("turn on the study fan", origin: .voice)
        XCTAssertEqual(reply.kind, .executed)
        XCTAssertEqual(reply.text, "Turned on Study Fan.")
        XCTAssertEqual(reply.source, AssistantCoordinator.grammarSource)
        XCTAssertTrue(planner.asked.isEmpty, "Level 1 never consults the model")
        XCTAssertEqual(store.power(for: fan), true)
    }

    func testStatusQuestion() async {
        let reply = await assistant.handle("is the study fan on", origin: .text)
        XCTAssertEqual(reply.kind, .status)
        XCTAssertEqual(reply.text, "Study Fan is off.")
    }

    func testMultiDeviceAsksThenYesRuns() async {
        let ask = await assistant.handle("turn on the study lamps", origin: .voice)
        XCTAssertEqual(ask.kind, .needsConfirmation)
        XCTAssertEqual(ask.text, "Turn on 2 lights in Study?")
        XCTAssertTrue(assistant.hasPendingConfirmation)
        XCTAssertEqual(store.power(for: lamp), false)
        let done = await assistant.handle("yes", origin: .voice)
        XCTAssertEqual(done.kind, .executed)
        XCTAssertEqual(done.text, "Turned on 2 lights in Study.")
        XCTAssertFalse(assistant.hasPendingConfirmation)
        XCTAssertEqual(store.power(for: lamp), true)
        XCTAssertEqual(store.power(for: lamp2), true)
        XCTAssertEqual(assistant.replies.count, 2)
    }

    func testNoCancelsPending() async {
        _ = await assistant.handle("turn off the study lamps", origin: .text)
        let reply = await assistant.handle("never mind", origin: .text)
        XCTAssertEqual(reply.kind, .info)
        XCTAssertFalse(assistant.hasPendingConfirmation)
    }

    func testNewCommandSupersedesPendingConfirmation() async {
        _ = await assistant.handle("turn on the study lamps", origin: .text)
        XCTAssertTrue(assistant.hasPendingConfirmation)
        _ = await assistant.handle("turn on the study fan", origin: .text)
        XCTAssertFalse(assistant.hasPendingConfirmation, "a stale yes must not fire the old plan")
        let reply = await assistant.handle("yes", origin: .text)
        XCTAssertEqual(reply.text, "Nothing is waiting for confirmation.")
        XCTAssertEqual(store.power(for: lamp), false)
    }

    func testAmbiguityCanBeAnsweredByName() async {
        let ask = await assistant.handle("turn on the lamp", origin: .voice)
        XCTAssertEqual(ask.kind, .ambiguous)
        XCTAssertNotNil(assistant.pendingChoice)
        let done = await assistant.handle("the desk one", origin: .voice)
        XCTAssertEqual(done.kind, .executed)
        XCTAssertEqual(done.text, "Turned on Desk Lamp.")
        XCTAssertNil(assistant.pendingChoice)
        XCTAssertEqual(store.power(for: lamp2), false)
    }

    func testOpenChoiceIgnoresACommandNamingAnotherDevice() async {
        // Open choice: Desk Lamp / Floor Lamp. "the fan" is a clear match to a
        // device outside the choice, so it must run as a NEW command.
        _ = await assistant.handle("turn on the lamp", origin: .voice)
        XCTAssertNotNil(assistant.pendingChoice)
        let reply = await assistant.handle("turn on the study fan", origin: .voice)
        XCTAssertEqual(reply.text, "Turned on Study Fan.")
        XCTAssertEqual(store.power(for: fan), true)
        XCTAssertEqual(store.power(for: lamp), false, "no candidate may run for a command naming another device")
        XCTAssertEqual(store.power(for: lamp2), false)
        XCTAssertNil(assistant.pendingChoice)
    }

    func testOpenChoiceRejectsPartialMatchAnswer() async {
        _ = await assistant.handle("turn on the lamp", origin: .voice)
        XCTAssertNotNil(assistant.pendingChoice)
        // "kitchen lamp" only partially matches the candidates ("lamp"): not a pick.
        let reply = await assistant.handle("turn on the kitchen lamp", origin: .voice)
        XCTAssertNotEqual(reply.text, "Turned on Desk Lamp.")
        XCTAssertEqual(store.power(for: lamp), false)
        XCTAssertEqual(store.power(for: lamp2), false)
    }

    func testUnknownPhrasingFallsToModelAndPlanIsConfirmedFirst() async {
        planner.plan = ProposedPlan(steps: [ProposedStep(deviceIDs: [lamp.id, lamp2.id], command: .level(30))],
                                    summary: "Dim both lamps for reading.")
        let ask = await assistant.handle("make it cosy in the study for reading", origin: .text)
        XCTAssertEqual(planner.asked, ["make it cosy in the study for reading"])
        XCTAssertEqual(planner.seenDevices, 3)
        XCTAssertEqual(ask.kind, .needsConfirmation)
        XCTAssertEqual(ask.source, AssistantCoordinator.modelSource)
        XCTAssertEqual(ask.text, "Dim both lamps for reading. Plan: Set 2 lights to 30%. Go ahead?")
        XCTAssertEqual(store.dps(for: lamp)["2"], .number(300), "nothing runs before the user agrees")
        let done = await assistant.handle("go ahead", origin: .text)
        XCTAssertEqual(done.kind, .executed)
        XCTAssertEqual(store.dps(for: lamp)["2"], .number(307))
        XCTAssertEqual(store.dps(for: lamp2)["2"], .number(307))
    }

    func testModelProposingUnknownDevicesIsRejected() async {
        planner.plan = ProposedPlan(steps: [ProposedStep(deviceIDs: ["ghost"], command: .power(true))], summary: "")
        let reply = await assistant.handle("do the thing", origin: .text)
        XCTAssertEqual(reply.kind, .error)
        XCTAssertTrue(reply.text.contains("ghost"))
        XCTAssertFalse(assistant.hasPendingConfirmation)
    }

    func testModelClarificationIsPassedThrough() async {
        planner.plan = ProposedPlan(steps: [], summary: "", clarification: "Which room do you mean?")
        let reply = await assistant.handle("dim the lights a bit", origin: .text)
        XCTAssertEqual(reply.kind, .ambiguous)
        XCTAssertEqual(reply.text, "Which room do you mean?")
    }

    func testModelUnavailableFallsBackToGrammarMessage() async {
        planner.isAvailable = false
        let reply = await assistant.handle("make it cosy", origin: .text)
        XCTAssertEqual(reply.kind, .error)
        XCTAssertEqual(reply.text, "Sorry, I didn't understand that (scripted off).")
        XCTAssertTrue(planner.asked.isEmpty)
        let none = AssistantCoordinator(controller: controller, planner: nil)
        let plain = await none.handle("make it cosy", origin: .text)
        XCTAssertEqual(plain.text, "Sorry, I didn't understand that.")
    }

    func testModelErrorIsReportedNotCrashing() async {
        planner.error = .failed("context too long")
        let reply = await assistant.handle("make it cosy", origin: .text)
        XCTAssertEqual(reply.kind, .error)
        XCTAssertEqual(reply.text, "The planner couldn't plan that: context too long.")
    }

    func testFullyUnderstoodSpeedCommandsNeverReachTheModel() async {
        for phrase in ["set the study fan speed to 2", "set the study fan speed to two", "change the study fan speed to do"] {
            let reply = await assistant.handle(phrase, origin: .voice)
            XCTAssertEqual(reply.source, AssistantCoordinator.grammarSource, phrase)
            XCTAssertEqual(reply.kind, .executed, phrase)
        }
        XCTAssertTrue(planner.asked.isEmpty, "the rule parser handled everything; the LLM is only for what it cannot parse")
    }

    func testHangingPlannerTimesOutAndSpinnerResets() async {
        planner.hangs = true
        assistant.timeouts = AssistantTimeouts(planner: 0.2, command: 1)
        let reply = await assistant.handle("make it cosy in the study", origin: .voice)
        XCTAssertEqual(reply.kind, .error)
        XCTAssertTrue(reply.text.contains("took too long"), reply.text)
        XCTAssertFalse(assistant.isBusy)
    }

    func testCancelAbandonsAHangingPlanner() async {
        planner.hangs = true
        assistant.timeouts = AssistantTimeouts(planner: 30, command: 30)
        let pending = Task { await assistant.handle("make it cosy in the study", origin: .voice) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(assistant.isBusy)
        assistant.cancelActive()
        let reply = await pending.value
        XCTAssertEqual(reply.text, "Cancelled.")
        XCTAssertFalse(assistant.isBusy)
    }

    func testOverBudgetCatalogueIsTrimmedToTheBestNameMatches() {
        let fillers = (0..<80).map { i in
            ControlFixtures.device("plug-\(i)", name: "Plug Number \(i)", category: "dj", room: "Hall", spec: ControlFixtures.lightSpec)
        }
        store.setRosterForTest([fan, lamp, lamp2] + fillers)
        let budget = 400
        let catalogue = PlannerCatalogue(devices: controller.summaries(), utterance: "study fan speed", budget: budget, maxDevices: 40, toolOutputBudget: 300)
        let text = catalogue.render()
        XCTAssertLessThanOrEqual(catalogue.shown.count, 40)
        XCTAssertGreaterThan(catalogue.omitted, 0)
        XCTAssertTrue(catalogue.shown.contains { $0.id == fan.id }, "the named device survives trimming")
        XCTAssertLessThanOrEqual(catalogue.shown.map { catalogue.line(for: $0).count + 1 }.reduce(0, +), budget)
        XCTAssertTrue(text.contains("findDevices"))
        XCTAssertFalse(text.contains(fan.id), "long ids are replaced by short handles")
        XCTAssertEqual(catalogue.id(forHandle: catalogue.handle(for: fan.id)), fan.id)
        XCTAssertLessThanOrEqual(catalogue.render(controller.summaries()).count, 300 + 60)
    }

    func testPlannerFactoryIsGatedNotCrashing() {
        // On this build host the factory may or may not return a planner;
        // either way it must not throw and the note must agree with it.
        let planner = PlannerFactory.makePlanner(controller: controller, defaults: UserDefaults(suiteName: "PlannerFactory-\(UUID())")!)
        XCTAssertNil(planner, "no model is contacted unless the user picks a provider")
    }
}

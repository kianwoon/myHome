import Foundation
import XCTest
@testable import MyHomeCore

private final class EchoBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        ["ok": true, "dps": payload["dps"] as Any]
    }
}

/// Scripted decisions endpoint: records request bodies, answers from a closure.
private final class RouteFakeJev: @unchecked Sendable {
    typealias Handler = @Sendable (_ body: [String: Any]) -> (Int, Data)
    private let lock = NSLock()
    private var _bodies: [[String: Any]] = []
    private var _handler: Handler = { _ in (500, Data()) }

    var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _bodies }
    var handler: Handler {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    var transport: JevTransport {
        ClosureJevTransport { [self] request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            lock.lock(); _bodies.append(body); let handler = _handler; lock.unlock()
            let (status, data) = handler(body)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static func envelope(_ rows: [String: (String, Double)]) -> Data {
        var answers: [String: Any] = [:]
        for (id, row) in rows { answers[id] = ["type": "choice", "choice": row.0, "probabilities": [row.0: row.1]] }
        return try! JSONSerialization.data(withJSONObject: ["model": "jev-1.13.0", "answers": answers])
    }

    static func questions(_ body: [String: Any]) -> [String: Any] { body["questions"] as? [String: Any] ?? [:] }
    static func isRoute(_ body: [String: Any]) -> Bool { questions(body)[JevCommandDecider.routeQuestionID] != nil }
}

@MainActor
private final class StubPlanner: NaturalLanguagePlanner {
    var isAvailable = true
    var unavailableReason: String? { isAvailable ? nil : "stub off" }
    var plan = ProposedPlan(steps: [], summary: "")
    var asked: [String] = []

    func plan(_ utterance: String, devices: [DeviceSummary]) async throws -> ProposedPlan {
        asked.append(utterance)
        return plan
    }
}

/// A key-shaped value built at runtime (never a literal key in the source).
private let testKey = ["sk", "or", "v1", String(repeating: "x", count: 24)].joined(separator: "-")

@MainActor
final class JevRouterTests: XCTestCase {
    private var store: DeviceStore!
    private var controller: DeviceController!
    private var defaults: UserDefaults!
    private var secrets: InMemorySecretStore!
    private var fake: RouteFakeJev!
    private var assistant: AssistantCoordinator!
    private var decider: JevCommandDecider!

    private let fan = ControlFixtures.device("fan-study", name: "Study Fan", category: "fs", room: "Study", spec: ControlFixtures.fanSpec)
    private let lamp = ControlFixtures.device("lamp-desk", name: "Desk Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let lamp2 = ControlFixtures.device("lamp-floor", name: "Floor Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)

    override func setUp() {
        super.setUp()
        store = DeviceStore(bridge: EchoBridge(), defaults: UserDefaults(suiteName: "JevRouterTests-store-\(UUID())")!)
        store.setRosterForTest([fan, lamp, lamp2])
        store.applyStatus(fan.id, decoded: ["1": .bool(false), "3": .number(2)])
        store.applyStatus(lamp.id, decoded: ["1": .bool(true), "2": .number(300)])
        store.applyStatus(lamp2.id, decoded: ["1": .bool(false), "2": .number(300)])
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 2))
        defaults = UserDefaults(suiteName: "JevRouterTests-\(UUID())")!
        defaults.set(true, forKey: AppSettings.jevEnabledKey)
        defaults.set("test/decider-0", forKey: AppSettings.jevModelKey)
        secrets = InMemorySecretStore()
        try? secrets.write(testKey, account: AppSettings.jevSecretAccount)
        fake = RouteFakeJev()
        decider = JevCommandDecider(defaults: defaults, secrets: secrets, transport: fake.transport, environment: [:])
        assistant = AssistantCoordinator(controller: controller)
        assistant.jevDecider = decider
    }

    private func routeAnswers(_ rows: [String: (String, Double)]) {
        fake.handler = { body in
            RouteFakeJev.isRoute(body) ? (200, RouteFakeJev.envelope(rows)) : (400, Data())
        }
    }

    private let routeID = JevCommandDecider.routeQuestionID

    // MARK: - route()

    func testRouteIsOneRequestWithTheQueryDetailsBatched() async throws {
        routeAnswers([routeID: ("command", 0.9)])
        let outcome = await decider.route("make the study nicer", devices: controller.summaries())
        XCTAssertEqual(outcome, .command(strength: 0.9))
        XCTAssertEqual(fake.bodies.count, 1)
        let questions = RouteFakeJev.questions(fake.bodies[0])
        XCTAssertEqual(Set(questions.keys), ["route", "kind", "state", "aggregation"])
        let routeCriteria = (questions["route"] as? [String: Any])?["criteria"] as? [String: String]
        XCTAssertEqual(Set(routeCriteria?.keys ?? [:].keys), ["command", "query", "inference", "other"])
        let kindCriteria = (questions["kind"] as? [String: Any])?["criteria"] as? [String: String]
        XCTAssertEqual(Set(kindCriteria?.keys ?? [:].keys), ["fan", "light", "any"], "only kinds present in the registry, plus any")
    }

    func testRouteLabels() async {
        let devices = controller.summaries()
        routeAnswers([routeID: ("inference", 0.8)])
        let inference = await decider.route("the room is stuffy", devices: devices)
        XCTAssertEqual(inference, .inference(strength: 0.8))
        routeAnswers([routeID: ("other", 0.95)])
        let other = await decider.route("tell me a joke", devices: devices)
        XCTAssertEqual(other, .other(strength: 0.95))
        routeAnswers([routeID: ("query", 0.9), "kind": ("light", 0.9), "state": ("on", 0.85), "aggregation": ("count", 0.9)])
        let query = await decider.route("tell me how many lamps are lit", devices: devices)
        XCTAssertEqual(query, .query(StateQuery(kind: .light, state: .on, aggregation: .count), strength: 0.9))
        routeAnswers([routeID: ("query", 0.9), "kind": ("any", 0.9), "state": ("off", 0.85), "aggregation": ("list", 0.9)])
        let anyKind = await decider.route("what's switched off", devices: devices)
        XCTAssertEqual(anyKind, .query(StateQuery(kind: nil, state: .off, aggregation: .list), strength: 0.9))
    }

    func testBelowGateUnmeasuredAndFailureAreUnsure() async {
        let devices = controller.summaries()
        routeAnswers([routeID: ("command", 0.4)])
        guard case .unsure(let reason) = await decider.route("hmm", devices: devices) else { return XCTFail("below gate must be unsure") }
        XCTAssertTrue(reason.contains("needs"), reason)
        routeAnswers([routeID: ("query", 0.9), "kind": ("light", 0.35), "state": ("on", 0.9), "aggregation": ("count", 0.9)])
        guard case .unsure = await decider.route("lamps?", devices: devices) else { return XCTFail("a weak detail row must not be guessed") }
        routeAnswers(["kind": ("light", 0.9)])
        guard case .unsure = await decider.route("x", devices: devices) else { return XCTFail("missing route row is unmeasured") }
        fake.handler = { _ in (503, Data()) }
        guard case .unsure = await decider.route("x", devices: devices) else { return XCTFail("failure fails open") }
    }

    // MARK: - Through the coordinator

    func testParserStateQueryNeverCallsJevOrThePlanner() async {
        let planner = StubPlanner()
        assistant.planner = planner
        let reply = await assistant.handle("how many lights are on", origin: .voice)
        XCTAssertEqual(reply.kind, .status)
        XCTAssertEqual(reply.source, AssistantCoordinator.grammarSource)
        // Prefix: a live BLE scan on the test host can add offline lights, which
        // are excluded from the count and only mentioned after it.
        XCTAssertTrue(reply.text.hasPrefix("1 of 2 lights is on: Desk Lamp."), reply.text)
        XCTAssertTrue(fake.bodies.isEmpty)
        XCTAssertTrue(planner.asked.isEmpty)
    }

    func testJevQueryIsAnsweredFromTheRegistry() async {
        routeAnswers([routeID: ("query", 0.9), "kind": ("light", 0.9), "state": ("off", 0.9), "aggregation": ("list", 0.9)])
        let reply = await assistant.handle("tell me the lamps that are dark", origin: .voice)
        XCTAssertEqual(reply.kind, .status)
        XCTAssertEqual(reply.source, AssistantCoordinator.jevSource)
        XCTAssertTrue(reply.text.hasPrefix("1 light is off: Floor Lamp."), reply.text)
        XCTAssertFalse(assistant.hasPendingConfirmation)
    }

    func testInferenceGoesToThePlannerAndWaitsForYes() async {
        let planner = StubPlanner()
        planner.plan = ProposedPlan(steps: [ProposedStep(deviceIDs: [fan.id], command: .power(true)),
                                            ProposedStep(deviceIDs: [fan.id], command: .fanSpeed(3))],
                                    summary: "Air the room.")
        assistant.planner = planner
        routeAnswers([routeID: ("inference", 0.9)])
        let reply = await assistant.handle("the room is very stuffy", origin: .voice)
        XCTAssertEqual(planner.asked, ["the room is very stuffy"])
        XCTAssertEqual(reply.kind, .needsConfirmation, reply.text)
        XCTAssertEqual(reply.source, AssistantCoordinator.modelSource)
        XCTAssertEqual(assistant.pending.count, 2)
        XCTAssertEqual(store.power(for: fan), false, "nothing runs before yes")
        _ = await assistant.handle("yes", origin: .voice)
        XCTAssertEqual(store.power(for: fan), true)
    }

    func testInferenceWithoutAPlannerExplainsAndRunsNothing() async {
        routeAnswers([routeID: ("inference", 0.9)])
        let reply = await assistant.handle("the room is very stuffy", origin: .voice)
        XCTAssertEqual(reply.kind, .info)
        XCTAssertTrue(reply.text.contains("Settings → AI Models"), reply.text)
        XCTAssertFalse(assistant.hasPendingConfirmation)
        XCTAssertEqual(fake.bodies.count, 1, "no matcher call for an inference")
        XCTAssertEqual(store.power(for: fan), false)

        let off = StubPlanner()
        off.isAvailable = false
        assistant.planner = off
        let again = await assistant.handle("the room is very stuffy", origin: .voice)
        XCTAssertTrue(again.text.contains("stub off"), again.text)
        XCTAssertTrue(off.asked.isEmpty)
        XCTAssertFalse(assistant.hasPendingConfirmation)
    }

    func testOtherIsNotUnderstood() async {
        routeAnswers([routeID: ("other", 0.9)])
        let reply = await assistant.handle("tell me a joke", origin: .text)
        XCTAssertEqual(reply.kind, .error)
        XCTAssertTrue(reply.text.contains("couldn't match it to a command"), reply.text)
        XCTAssertEqual(fake.bodies.count, 1)
    }

    func testRouteUnsureUsesThePlannerWhenAvailable() async {
        let planner = StubPlanner()
        planner.plan = ProposedPlan(steps: [ProposedStep(deviceIDs: [fan.id], command: .power(true))], summary: "")
        assistant.planner = planner
        fake.handler = { _ in (503, Data()) }
        let reply = await assistant.handle("the room is very stuffy", origin: .voice)
        XCTAssertEqual(planner.asked.count, 1)
        XCTAssertEqual(reply.kind, .needsConfirmation)
        XCTAssertEqual(store.power(for: fan), false)
    }

    func testRouteUnsureWithoutAPlannerFallsBackToTheMatcher() async {
        fake.handler = { body in
            if RouteFakeJev.isRoute(body) { return (200, RouteFakeJev.envelope(["route": ("command", 0.4)])) }
            return (503, Data())
        }
        let reply = await assistant.handle("the room is very stuffy", origin: .voice)
        XCTAssertGreaterThan(fake.bodies.count, 1, "the matcher (Stage A) was tried after the unsure route")
        XCTAssertTrue(reply.text.contains(AssistantCoordinator.jevUnsureLead), reply.text)
        XCTAssertFalse(assistant.hasPendingConfirmation)
    }

    func testWithoutJevThePlannerHandlesUnknownAsBefore() async {
        let planner = StubPlanner()
        planner.plan = ProposedPlan(steps: [ProposedStep(deviceIDs: [fan.id], command: .power(true))], summary: "")
        assistant.planner = planner
        assistant.jevDecider = nil
        let reply = await assistant.handle("the room is very stuffy", origin: .voice)
        XCTAssertEqual(planner.asked.count, 1)
        XCTAssertEqual(reply.kind, .needsConfirmation)
        XCTAssertTrue(fake.bodies.isEmpty)
    }

    // MARK: - Settings migration / factory

    func testLegacyJevProviderMigratesOnceAndIdempotently() {
        let legacy = UserDefaults(suiteName: "JevMigration-\(UUID())")!
        legacy.set(AppSettings.legacyJevProviderRawValue, forKey: AppSettings.plannerProviderKey)
        XCTAssertEqual(AppSettings.plannerProvider(from: legacy), .none, "the legacy raw value no longer decodes")
        XCTAssertTrue(AppSettings.migrateLegacyJevProvider(legacy))
        XCTAssertTrue(AppSettings.jevEnabled(from: legacy))
        XCTAssertEqual(legacy.string(forKey: AppSettings.plannerProviderKey), AppSettings.PlannerProvider.none.rawValue)
        XCTAssertFalse(AppSettings.migrateLegacyJevProvider(legacy), "second run is a no-op")
        XCTAssertTrue(AppSettings.jevEnabled(from: legacy))

        let cloud = UserDefaults(suiteName: "JevMigration-\(UUID())")!
        cloud.set(AppSettings.PlannerProvider.anthropic.rawValue, forKey: AppSettings.plannerProviderKey)
        XCTAssertFalse(AppSettings.migrateLegacyJevProvider(cloud))
        XCTAssertEqual(AppSettings.plannerProvider(from: cloud), .anthropic)
        XCTAssertFalse(AppSettings.jevEnabled(from: cloud), "Jev stays off by default")
    }

    func testJevAndCloudPlannerCanBothBeActive() {
        defaults.set(AppSettings.PlannerProvider.anthropic.rawValue, forKey: AppSettings.plannerProviderKey)
        XCTAssertNotNil(PlannerFactory.makeJevDecider(defaults: defaults, secrets: secrets, transport: fake.transport))
        XCTAssertTrue(PlannerFactory.makePlanner(controller: controller, defaults: defaults, secrets: secrets) is CloudPlanner)
        defaults.set(false, forKey: AppSettings.jevEnabledKey)
        XCTAssertNil(PlannerFactory.makeJevDecider(defaults: defaults, secrets: secrets, transport: fake.transport))
        XCTAssertNotNil(PlannerFactory.makePlanner(controller: controller, defaults: defaults, secrets: secrets))
    }
}

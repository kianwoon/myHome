import Foundation
import XCTest
@testable import MyHomeCore

private final class NoopBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { ["ok": true] }
}

@MainActor
final class StudyLightShadowTests: XCTestCase {
    private var store: DeviceStore!
    private var controller: DeviceController!

    private let plug = ControlFixtures.device("plug-study", name: "Study light", category: "cz", ip: "")
    private let briturnA = ControlFixtures.device("briturn-aabbccdd8bdb", name: "Briturn Light 8bdb", category: "briturn", group: "Study")
    private let briturnB = ControlFixtures.device("briturn-aabbccdd1111", name: "Briturn Light 1111", category: "briturn", group: "Study")

    private func makeController(_ roster: [Device]) {
        store = DeviceStore(bridge: NoopBridge(), defaults: UserDefaults(suiteName: "StudyLightShadowTests-\(UUID())")!)
        store.setRosterForTest(roster)
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 2))
    }

    func testPlugNamedLightClassifiesAsPlug() {
        XCTAssertEqual(plug.kind, .plug)
        XCTAssertEqual(DeviceKind.classify(category: "cz", name: "Study light"), .plug)
    }

    func testPlugNamedLightDoesNotShadowRoomBriturnLights() {
        makeController([plug, briturnA, briturnB])
        var query = DeviceQuery(text: "study light")
        query.requiredCapability = .level
        let resolution = controller.resolve(query)
        XCTAssertFalse(resolution.devices.contains { $0.id == plug.id }, "got \(resolution)")
        XCTAssertFalse(resolution.devices.isEmpty, "got \(resolution)")
    }

    func testSetStudyLightTo50NeverTargetsThePlugButReportsIt() async {
        makeController([plug, briturnA, briturnB])
        // Dimming: the socket cannot dim, so it is not even a candidate; the lights are asked about.
        let dim = await controller.perform(.level(50), on: DeviceQuery(text: "study light"), origin: .text)
        XCTAssertFalse(dim.outcomes.contains { $0.device.id == plug.id }, "\(dim.disposition) \(dim.spokenSummary)")
        XCTAssertTrue(dim.spokenSummary.hasPrefix("Which one: "), dim.spokenSummary)
        // Power: the socket is a namesake with no control path — set aside, but named, never written.
        let off = await controller.perform(.power(false), on: DeviceQuery(text: "study light"), origin: .text)
        guard case .denied = off.outcomes.first(where: { $0.device.id == plug.id })?.status else {
            return XCTFail("the plug must be reported as denied: \(off.disposition) \(off.spokenSummary)")
        }
        XCTAssertTrue(off.spokenSummary.contains("Study light has no control path"), off.spokenSummary)
    }

    func testNamedLightCategoriesOtherThanLightsStayPlugs() {
        for category in ["cz", "kg", "CZ"] {
            XCTAssertEqual(DeviceKind.classify(category: category, name: "Study light"), .plug, category)
            XCTAssertEqual(DeviceKind.classify(category: category, name: "Desk lamp"), .plug, category)
        }
        XCTAssertEqual(DeviceKind.classify(category: "", name: "Study light"), .light, "no category: the name still decides")
    }

    func testResolverPrefersControllableNamesakeOverUnreachableExactName() {
        let roster = [plug, briturnA]
        let reach: (Device) -> Bool = { $0.hasAddress }
        let resolver = DeviceResolver(devices: roster, isControllable: reach)
        XCTAssertEqual(resolver.resolve(DeviceQuery(text: "study light")), .single(plug), "status/default behaviour unchanged")
        let command = resolver.resolve(DeviceQuery(text: "study light", preferControllable: true))
        XCTAssertEqual(command, .single(briturnA))
    }

    func testPreferControllableKeepsTheUnreachableDeviceWhenNothingElseMatches() {
        let resolver = DeviceResolver(devices: [plug, briturnA], isControllable: { $0.hasAddress })
        XCTAssertEqual(resolver.resolve(DeviceQuery(text: "study light", kind: .plug, preferControllable: true)), .single(plug))
    }
}

private final class RecordingPlanner: NaturalLanguagePlanner {
    var isAvailable = true
    var unavailableReason: String? { isAvailable ? nil : "off" }
    var asked: [String] = []
    var plan = ProposedPlan(steps: [], summary: "")
    func plan(_ utterance: String, devices: [DeviceSummary]) async throws -> ProposedPlan {
        asked.append(utterance)
        return plan
    }
}

@MainActor
final class PlannerWithoutHousekeeperTests: XCTestCase {
    private var store: DeviceStore!
    private var controller: DeviceController!
    private let lamp = ControlFixtures.device("lamp-desk", name: "Desk Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let lamp2 = ControlFixtures.device("lamp-floor", name: "Floor Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let plug = ControlFixtures.device("plug-study", name: "Study light", category: "cz", ip: "")

    override func setUp() {
        super.setUp()
        store = DeviceStore(bridge: NoopBridge(), defaults: UserDefaults(suiteName: "PlannerEscalationTests-\(UUID())")!)
        store.setRosterForTest([lamp, lamp2, plug])
        store.applyStatus(lamp.id, decoded: ["1": .bool(false), "2": .number(300)])
        store.applyStatus(lamp2.id, decoded: ["1": .bool(true), "2": .number(300)])
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 5))
    }

    func testAmbiguousCommandWithoutAPlannerKeepsTheGrammarQuestion() async {
        let assistant = AssistantCoordinator(controller: controller, planner: nil)
        let reply = await assistant.handle("set study lamp to 50%", origin: .text)
        XCTAssertEqual(reply.kind, .ambiguous)
        XCTAssertEqual(reply.source, AssistantCoordinator.grammarSource)
    }

    func testUnavailablePlannerKeepsTheGrammarQuestion() async {
        let planner = RecordingPlanner()
        planner.isAvailable = false
        let assistant = AssistantCoordinator(controller: controller, planner: planner)
        let reply = await assistant.handle("set study lamp to 50%", origin: .text)
        XCTAssertEqual(reply.kind, .ambiguous)
        XCTAssertTrue(planner.asked.isEmpty)
    }

    func testDirectlyExecutableCommandNeverReachesThePlanner() async {
        let planner = RecordingPlanner()
        let assistant = AssistantCoordinator(controller: controller, planner: planner)
        let reply = await assistant.handle("turn on the desk lamp", origin: .text)
        XCTAssertEqual(reply.kind, .executed)
        XCTAssertTrue(planner.asked.isEmpty)
    }
}

@MainActor
final class HousekeeperPersonaTests: XCTestCase {
    func testDefaultInstructionsCarryRoleStateAwarenessAndOneQuestionRule() {
        let text = CloudPlanner.defaultInstructions.lowercased()
        XCTAssertTrue(text.contains("head housekeeper"))
        XCTAssertTrue(text.contains("current state"))
        XCTAssertTrue(text.contains("dim only what is lit"))
        XCTAssertTrue(text.contains("one short clarifying question"))
        XCTAssertTrue(text.contains("never invent"))
        XCTAssertTrue(text.contains("handles"))
        XCTAssertTrue(text.contains("0-100"), "the output contract survives")
        if #available(macOS 26, *) {
            XCTAssertTrue(FoundationModelsPlanner.defaultInstructions.lowercased().contains("head housekeeper"))
        }
    }

    func testPersonaStaysWithinThePromptBudgetAlongsideTheCatalogue() {
        let persona = PlannerPersona.housekeeper
        XCTAssertLessThanOrEqual(persona.split(whereSeparator: \.isWhitespace).count, 250)
        let system = CloudPlanner.systemPrompt(CloudPlanner.defaultInstructions)
        // ~3 characters per token, conservatively, against the 8,192-token on-device window
        // (the cloud path has a far larger budget; this guards the Apple FM path).
        XCTAssertLessThan((system.count + AppSettings.defaultPlannerCatalogueBudget) / 3, 8192)
    }

    func testCustomInstructionsOverrideTheDefault() {
        let defaults = UserDefaults(suiteName: "HousekeeperPersonaTests-\(UUID())")!
        XCTAssertEqual(AppSettings.plannerInstructions(from: defaults, fallback: "default"), "default")
        defaults.set("  custom  ", forKey: AppSettings.plannerInstructionsKey)
        XCTAssertEqual(AppSettings.plannerInstructions(from: defaults, fallback: "default"), "custom")
        defaults.removeObject(forKey: AppSettings.plannerInstructionsKey)
        XCTAssertEqual(AppSettings.plannerInstructions(from: defaults, fallback: "default"), "default")
    }
}

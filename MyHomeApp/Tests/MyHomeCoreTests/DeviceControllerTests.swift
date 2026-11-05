import Foundation
import XCTest
@testable import MyHomeCore

/// Bridge whose replies are scripted per command; records every request.
private final class ScriptedBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String: Any]] = []
    var handler: ([String: Any]) throws -> [String: Any] = { _ in ["ok": true] }
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return log }
    private func record(_ payload: [String: Any]) { lock.lock(); log.append(payload); lock.unlock() }

    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        record(payload)
        return try handler(payload)
    }
}

private struct Boom: Error {}

@MainActor
final class DeviceControllerTests: XCTestCase {
    private var bridge: ScriptedBridge!
    private var store: DeviceStore!
    private var controller: DeviceController!

    private let fan = ControlFixtures.device("fan-study", name: "Study Fan", category: "fs", room: "Study", spec: ControlFixtures.fanSpec)
    private let light = ControlFixtures.device("light-1", name: "Desk Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let light2 = ControlFixtures.device("light-2", name: "Floor Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let unreachable = ControlFixtures.device("plug-x", name: "Garage Plug", category: "cz", ip: "")
    private let bulb = ControlFixtures.device("briturn-aabbccddeeff", name: "Reading Lamp", category: "briturn", group: "Study")

    override func setUp() {
        super.setUp()
        bridge = ScriptedBridge()
        store = DeviceStore(bridge: bridge, defaults: UserDefaults(suiteName: "DeviceControllerTests-\(UUID())")!)
        store.setRosterForTest([fan, light, light2, unreachable, bulb])
        store.applyStatus(fan.id, decoded: ["1": .bool(false), "2": .string("custom"), "3": .number(2)])
        store.applyStatus(light.id, decoded: ["1": .bool(false), "2": .number(300), "3": .number(500)])
        store.applyStatus(light2.id, decoded: ["1": .bool(false), "2": .number(300)])
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 2))
    }

    private func setRequests() -> [[String: Any]] { bridge.requests.filter { $0["cmd"] as? String == "set" } }

    func testConfirmedWhenBridgeEchoesTheValue() async {
        bridge.handler = { payload in ["ok": true, "dps": payload["dps"] as Any] }
        let result = await controller.perform(.power(true), on: DeviceQuery(text: "study fan"), origin: .text)
        XCTAssertEqual(result.disposition, .executed)
        XCTAssertEqual(result.outcomes.map(\.status), [.confirmed])
        XCTAssertEqual(store.power(for: fan), true)
        XCTAssertEqual(setRequests().count, 1)
        XCTAssertEqual((setRequests()[0]["dps"] as? [String: Any])?["1"] as? Bool, true)
        XCTAssertEqual(result.spokenSummary, "Turned on Study Fan.")
    }

    func testFanPercentBecomesGearWriteOnTheStatusKey() async {
        bridge.handler = { payload in ["ok": true, "dps": payload["dps"] as Any] }
        let result = await controller.perform(.level(50), on: DeviceQuery(text: "study fan"), origin: .voice)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual((setRequests()[0]["dps"] as? [String: Any])?["3"] as? Int, 3)
        XCTAssertEqual(store.dps(for: fan)["3"], .number(3))
    }

    func testDefiniteRejectionRevertsAndReports() async {
        bridge.handler = { _ in ["ok": false, "error": "bad device id"] }
        let result = await controller.perform(.power(true), on: DeviceQuery(text: "study fan"), origin: .text)
        XCTAssertEqual(result.outcomes.map(\.status), [.rejected("bad device id")])
        XCTAssertEqual(store.power(for: fan), false, "store reverted the optimistic paint")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.spokenSummary, "Couldn't turn on Study Fan: bad device id.")
    }

    func testTransportErrorIsUncertainNotRejected() async {
        bridge.handler = { _ in throw Boom() }
        let result = await controller.perform(.power(true), on: DeviceQuery(text: "study fan"), origin: .text)
        guard case .uncertain = result.outcomes[0].status else { return XCTFail("expected uncertain, got \(result.outcomes[0].status)") }
        XCTAssertEqual(store.power(for: fan), true, "optimistic paint kept for the poll to settle")
    }

    func testContinuousWriteWithoutEchoIsUnverified() async {
        bridge.handler = { _ in ["ok": true] }
        let result = await controller.perform(.level(50), on: DeviceQuery(text: "desk lamp"), origin: .text)
        XCTAssertEqual(result.outcomes.map(\.status), [.unverified])
        XCTAssertEqual((setRequests()[0]["dps"] as? [String: Any])?["2"] as? Int, 505)
        XCTAssertEqual(store.dps(for: light)["2"], .number(300), "no optimistic paint for a slider-style value")
        XCTAssertEqual(result.spokenSummary, "Set Desk Lamp to 50% (not yet confirmed by the device).")
    }

    func testMultiDeviceNeedsConfirmationThenRuns() async {
        bridge.handler = { payload in ["ok": true, "dps": payload["dps"] as Any] }
        // "study lamps": the two Tuya lamps by room, the Briturn lamp by group.
        // (A bare "lamps" would also include BLE lights other test classes
        // register on the shared BLEManager, so the query stays name-scoped.)
        let first = await controller.perform(.power(true), on: DeviceQuery(text: "study lamps"), origin: .voice)
        XCTAssertEqual(first.disposition, .needsConfirmation(deviceCount: 3))
        XCTAssertTrue(setRequests().isEmpty, "nothing sent before confirmation")
        XCTAssertEqual(first.spokenSummary, "Turn on 3 lights?")
        guard let pending = first.pendingRequest else { return XCTFail("missing pending request") }
        XCTAssertTrue(pending.confirmed)
        let second = await controller.perform(pending)
        XCTAssertEqual(second.disposition, .executed)
        XCTAssertEqual(setRequests().count, 2, "two Tuya lamps over the bridge; the Briturn lamp uses its own path")
        XCTAssertEqual(second.outcomes.count, 3)
    }

    func testPolicyDeniesDevicesWithoutAControlPath() async {
        let result = await controller.perform(.power(false), on: DeviceQuery(text: "garage plug"), origin: .siri)
        XCTAssertEqual(result.outcomes.count, 1)
        guard case .denied = result.outcomes[0].status else { return XCTFail("expected denial") }
        XCTAssertTrue(setRequests().isEmpty)
    }

    func testUnsupportedCommandIsReportedNotSent() async {
        let result = await controller.perform(.fanSpeed(3), on: DeviceQuery(text: "desk lamp"), origin: .text)
        XCTAssertEqual(result.outcomes.map(\.status), [.unsupported("does not support fanSpeed")])
        XCTAssertTrue(setRequests().isEmpty)
    }

    func testAmbiguityIsSurfaced() async {
        let result = await controller.perform(.power(true), on: DeviceQuery(text: "lamp"), origin: .text)
        guard case .ambiguous(let candidates) = result.disposition else { return XCTFail("expected ambiguity") }
        XCTAssertEqual(Set(candidates.map(\.name)), ["Desk Lamp", "Floor Lamp", "Reading Lamp"])
        XCTAssertTrue(setRequests().isEmpty)
        XCTAssertTrue(result.spokenSummary.hasPrefix("Which one: "))
    }

    func testBriturnSingleWriteGoesThroughSetBriturn() async {
        bridge.handler = { _ in ["ok": true] }
        let result = await controller.perform(.power(true), on: DeviceQuery(text: "reading lamp"), origin: .text)
        XCTAssertEqual(result.outcomes.map(\.status), [.confirmed])
        XCTAssertEqual(bridge.requests.last?["cmd"] as? String, "briturnset")
        XCTAssertEqual(store.briturnStatus[bulb.id]?.on, true)
    }

    func testBriturnGroupKeepsDenialForOfflineMembersAndDoesNotWaitOnThem() async {
        bridge.handler = { _ in ["ok": true] }
        let live = ControlFixtures.device("briturn-001122334455", name: "Hall One", category: "briturn", group: "Hall")
        let offA = ControlFixtures.device("briturn-001122334466", name: "Hall Two", category: "briturn", group: "Hall", ip: "", online: false)
        let offB = ControlFixtures.device("briturn-001122334477", name: "Hall Three", category: "briturn", group: "Hall", ip: "", online: false)
        store.setRosterForTest([live, offA, offB])
        let members = [live, offA, offB]
        func run(timeout: TimeInterval) async -> (CommandResult, TimeInterval) {
            let ctl = DeviceController(store: store, config: ControlConfig(verifyTimeout: timeout, confirmationDeviceThreshold: 10))
            let started = Date()
            let result = await ctl.perform(CommandRequest(resolution: .briturnGroup("Hall", members: members),
                                                          command: .power(true), origin: .text, confirmed: true))
            return (result, Date().timeIntervalSince(started))
        }
        let timeout: TimeInterval = 1.0
        let baseline = await run(timeout: 0).1
        let (result, elapsed) = await run(timeout: timeout)
        XCTAssertEqual(controller.summary(for: offA).reachability, .offline)
        XCTAssertEqual(result.outcomes.count, 3)
        for outcome in result.outcomes where outcome.device.id != live.id {
            guard case .denied = outcome.status else { return XCTFail("offline member must stay denied, got \(outcome.status)") }
        }
        // Only the one member that was written may wait the verify timeout.
        XCTAssertLessThan(elapsed - baseline, timeout * 1.8, "denied members must not each wait the verify timeout")
    }

    func testSummariesExposeCapabilitiesAndState() {
        let summary = controller.summary(for: fan)
        XCTAssertEqual(summary.capabilities, [.fanSpeed, .level, .mode, .power])
        XCTAssertEqual(summary.isOn, false)
        XCTAssertEqual(summary.levelPercent, 33)
        XCTAssertEqual(summary.reachability, .wifi)
        XCTAssertEqual(CommandPhrasing.describe(summary), "Study Fan is off")
        XCTAssertEqual(controller.summary(for: unreachable).reachability, .offline)
    }

    func testStateWaiterResolvesOnPublishedChange() async {
        let waiter = StateWaiter(store: store)
        Task { @MainActor [store] in
            store!.applyStatus("fan-study", decoded: ["1": .bool(true)])
        }
        let seen = await waiter.wait(until: { [store] in store!.power(for: self.fan) == true }, timeout: 1)
        XCTAssertTrue(seen)
        let timedOut = await StateWaiter(store: store).wait(until: { false }, timeout: 0.05)
        XCTAssertFalse(timedOut)
    }
}

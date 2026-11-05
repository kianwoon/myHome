import Foundation
import XCTest
@testable import MyHomeCore

/// Bridge scripted per command: `set` and `status` answer independently, so a
/// device can accept a write and still report its old state.
private final class VerifyBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String: Any]] = []
    var onSet: ([String: Any]) throws -> [String: Any] = { _ in ["ok": true] }
    var onStatus: (String) -> [String: Any] = { _ in ["ok": false, "error": "no status"] }
    var onBriturnSet: ([String: Any]) -> [String: Any] = { _ in ["ok": true] }
    var onGroupSet: ([String: Any]) -> [String: Any] = { _ in ["ok": true] }
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return log }
    var commands: [String] { requests.compactMap { $0["cmd"] as? String } }
    private func record(_ payload: [String: Any]) { lock.lock(); log.append(payload); lock.unlock() }

    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        record(payload)
        switch payload["cmd"] as? String {
        case "set": return try onSet(payload)
        case "status": return onStatus(payload["id"] as? String ?? "")
        case "briturnset": return onBriturnSet(payload)
        case "briturnsetgroup": return onGroupSet(payload)
        default: return ["ok": true]
        }
    }
}

private final class BLESends: @unchecked Sendable { var sent: [(key: String, on: Bool?)] = [] }

@MainActor
final class DeviceControllerVerifyTests: XCTestCase {
    private var bridge: VerifyBridge!
    private var store: DeviceStore!
    private var controller: DeviceController!
    private let lamp = ControlFixtures.device("light-1", name: "Desk Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let bulb = ControlFixtures.device("briturn-aabbccdd8e6d", name: "Front A", category: "briturn", group: "study", ip: "10.255.0.62", online: true)
    private let bulb2 = ControlFixtures.device("briturn-aabbccdd931d", name: "Front B", category: "briturn", group: "study", ip: "10.255.0.67", online: true)
    private let bleOnly = ControlFixtures.device("briturn-aabbccdd89e3", name: "Back B", category: "briturn", group: "hall", ip: "", online: false)
    private let plug = ControlFixtures.device("plug-study", name: "Study light", category: "cz", room: "Study", ip: "")
    private let bleKey = "ble-11111111-2222-3333-4444-555555555555"

    private func lit(_ on: Bool, level: Int = 255) -> DeviceStore.BriturnState {
        DeviceStore.BriturnState(on: on, rawPower: on ? 0x23 : 0x24, mode: 97, r: level, g: level, b: level, w: 0)
    }

    override func setUp() {
        super.setUp()
        bridge = VerifyBridge()
        store = DeviceStore(bridge: bridge, defaults: UserDefaults(suiteName: "DeviceControllerVerifyTests-\(UUID())")!)
        store.setRosterForTest([lamp, bulb, bulb2, bleOnly, plug])
        store.applyStatus(lamp.id, decoded: ["1": .bool(false), "2": .number(300)])
        store.setBriturnStatus(bulb.id, lit(true))
        store.setBriturnStatus(bulb2.id, lit(true))
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 1, confirmationDeviceThreshold: 10, settleInterval: 0.2))
    }

    private func attachBluetooth(live: Bool = true) -> BLESends {
        store.bleFallbackIDs = [bleOnly.id]
        store.bleKeysByDeviceID[bleOnly.id] = [bleKey]
        store.bleLiveHook = { [bleKey] key in live && key == bleKey }
        let sends = BLESends()
        store.briturnBLESendHook = { key, on in sends.sent.append((key, on)) }
        return sends
    }

    private func status(_ id: String) -> OutcomeStatus? { lastResult?.outcomes.first { $0.device.id == id }?.status }
    private var lastResult: CommandResult?

    // MARK: Positive evidence only

    func testTuyaReplyEchoIsEvidenceAndStatusReadBackIsTheFallback() async {
        // Echo: the device answered the set with the new dps.
        bridge.onSet = { payload in ["ok": true, "dps": payload["dps"] as Any] }
        var result = await controller.perform(.power(true), on: DeviceQuery(text: "desk lamp"), origin: .text)
        XCTAssertEqual(result.outcomes.map(\.status), [.confirmed])
        XCTAssertTrue(result.succeeded)
        // No echo: the status read-back decides.
        bridge.onSet = { _ in ["ok": true] }
        bridge.onStatus = { _ in ["ok": true, "dps": ["1": true, "2": 1000]] }
        result = await controller.perform(.level(100), on: DeviceQuery(text: "desk lamp"), origin: .text)
        XCTAssertEqual(result.outcomes.map(\.status), [.confirmed], "\(result.spokenSummary)")
        XCTAssertTrue(bridge.commands.contains("status"), "the device was read back")
    }

    func testDeviceThatAcceptsTheWriteButNeverChangesIsNotConfirmed() async {
        bridge.onSet = { _ in ["ok": true] }
        bridge.onStatus = { _ in ["ok": true, "dps": ["1": false, "2": 300]] }   // still the old state
        let result = await controller.perform(.level(50), on: DeviceQuery(text: "desk lamp"), origin: .text)
        guard case .rejected(let reason) = result.outcomes[0].status else { return XCTFail("expected rejected, got \(result.outcomes[0].status)") }
        XCTAssertTrue(reason.contains("still reports"), reason)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.spokenSummary.hasPrefix("Couldn't set Desk Lamp to 50%: the device still reports"), result.spokenSummary)
        XCTAssertGreaterThan(bridge.commands.filter { $0 == "status" }.count, 1, "read back more than once within the verify window")
    }

    func testTransportErrorWithoutReadBackStaysUncertainNotConfirmed() async {
        struct Boom: Error {}
        bridge.onSet = { _ in throw Boom() }
        bridge.onStatus = { _ in ["ok": false, "error": "offline"] }
        let result = await controller.perform(.power(true), on: DeviceQuery(text: "desk lamp"), origin: .text)
        guard case .uncertain = result.outcomes[0].status else { return XCTFail("expected uncertain, got \(result.outcomes[0].status)") }
        XCTAssertFalse(result.succeeded)
    }

    func testUnknownStateDeviceIsReadFirstAndNamed() async {
        let fresh = ControlFixtures.device("light-2", name: "Floor Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
        store.setRosterForTest([lamp, fresh])
        bridge.onStatus = { id in id == fresh.id ? ["ok": true, "dps": ["1": true, "2": 300]] : ["ok": false, "error": "x"] }
        bridge.onSet = { payload in ["ok": true, "dps": payload["dps"] as Any] }
        XCTAssertNil(store.power(for: fresh), "no reading yet")
        let result = await controller.perform(.power(true), on: DeviceQuery(text: "floor lamp"), origin: .text)
        XCTAssertEqual(bridge.commands.prefix(2), ["status", "set"], "pre-check reads the unknown device before writing: \(bridge.commands)")
        XCTAssertEqual(result.outcomes.map { $0.device.name }, ["Floor Lamp"])
        XCTAssertEqual(result.outcomes.map(\.status), [.confirmed])
    }

    func testUnreachableNamesakeIsReportedNotDropped() async {
        bridge.onBriturnSet = { _ in ["ok": true] }
        store.briturnLANReadHook = { [store] device in store?.briturnStatus[device.id] }
        let result = await controller.perform(.power(false), on: DeviceQuery(text: "study light"), origin: .text)
        let plugOutcome = result.outcomes.first { $0.device.id == plug.id }
        guard case .denied = plugOutcome?.status else { return XCTFail("the socket must be reported as denied: \(result.outcomes)") }
        XCTAssertFalse(bridge.requests.contains { $0["id"] as? String == plug.id }, "nothing is ever sent to it")
        XCTAssertTrue(result.spokenSummary.contains("Study light has no control path"), result.spokenSummary)
    }

    // MARK: Briturn: per-device writes, Bluetooth, bridge results

    func testLANAndBluetoothMembersAreWrittenOneByOneAndBluetoothStaysUnverified() async {
        let sends = attachBluetooth()
        store.briturnLANReadHook = { [store] device in store?.briturnStatus[device.id] }
        let result = await controller.perform(CommandRequest(resolution: .set([bulb, bulb2, bleOnly], scope: .all),
                                                             command: .power(false), origin: .model, confirmed: true))
        XCTAssertEqual(bridge.commands.filter { $0 == "briturnset" }.count, 2)
        XCTAssertFalse(bridge.commands.contains("briturnsetgroup"))
        XCTAssertEqual(sends.sent.map(\.key), [bleKey])
        lastResult = result
        XCTAssertEqual(status(bulb.id), .confirmed)
        XCTAssertEqual(status(bulb2.id), .confirmed)
        XCTAssertEqual(status(bleOnly.id)?.isUnverified, true, "\(String(describing: status(bleOnly.id)))")
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.spokenSummary.contains("Back B not yet confirmed"), result.spokenSummary)
    }

    func testBluetoothAdvertAfterTheSendConfirmsOrContradicts() async {
        _ = attachBluetooth()
        let heard = Date().addingTimeInterval(1)   // an advert newer than the write
        store.bleLastAdvertHook = { _ in heard }
        store.bleStateReadHook = { [weak self] _ in self?.lit(true) }
        var result = await controller.perform(.power(true), on: DeviceQuery(ids: [bleOnly.id]), origin: .text)
        XCTAssertEqual(result.outcomes.map(\.status), [.confirmed], "\(result.spokenSummary)")
        store.bleStateReadHook = { [weak self] _ in self?.lit(true) }   // still on after an "off" command
        result = await controller.perform(.power(false), on: DeviceQuery(ids: [bleOnly.id]), origin: .text)
        guard case .rejected(let reason) = result.outcomes[0].status else { return XCTFail("expected rejected: \(result.outcomes[0].status)") }
        XCTAssertTrue(reason.contains("still reports on"), reason)
        // An advert older than the command proves nothing.
        store.bleLastAdvertHook = { _ in Date().addingTimeInterval(-60) }
        result = await controller.perform(.power(false), on: DeviceQuery(ids: [bleOnly.id]), origin: .text)
        XCTAssertEqual(result.outcomes[0].status.isUnverified, true, "\(result.outcomes[0].status)")
        XCTAssertTrue(result.outcomes[0].status.reason.contains("no Bluetooth advert since the command"), result.outcomes[0].status.reason)
        // A cached advert state with no timestamp proves nothing either.
        store.bleLastAdvertHook = { _ in nil }
        store.bleStateReadHook = { [weak self] _ in self?.lit(false) }
        result = await controller.perform(.power(false), on: DeviceQuery(ids: [bleOnly.id]), origin: .text)
        XCTAssertEqual(result.outcomes[0].status.isUnverified, true, "\(result.outcomes[0].status)")
        XCTAssertTrue(result.outcomes[0].status.reason.contains("no Bluetooth advert timestamp"), result.outcomes[0].status.reason)
    }

    func testBrightnessOverBluetoothIsUnverifiableNotConfirmed() async {
        _ = attachBluetooth()
        store.bleLastAdvertHook = { _ in Date().addingTimeInterval(1) }
        store.bleStateReadHook = { [weak self] _ in self?.lit(true, level: 128) }
        let result = await controller.perform(.level(50), on: DeviceQuery(ids: [bleOnly.id]), origin: .text)
        XCTAssertEqual(result.outcomes[0].status.isUnverified, true)
        XCTAssertTrue(result.outcomes[0].status.reason.contains("adverts cannot confirm brightness"), result.outcomes[0].status.reason)
    }

    func testBridgeGroupResultsMarkTheMissedLightFailedAndClearStaleErrors() async {
        store.statusErrors[bulb.id] = "Light unreachable."   // stale from an earlier sweep
        bridge.onGroupSet = { [bulb, bulb2] _ in ["ok": true, "applied": 1, "results": [bulb.id: true, bulb2.id: false]] }
        let acks = await store.setBriturnGroupState("study", on: false)
        XCTAssertEqual(acks[bulb.id], .applied(readback: nil))
        XCTAssertEqual(acks[bulb2.id], .failed(DeviceStore.lanMissMessage))
        XCTAssertNil(store.statusErrors[bulb.id], "a confirmed member sheds its stale error")
        XCTAssertEqual(store.statusErrors[bulb2.id], DeviceStore.lanMissMessage)
        XCTAssertEqual(store.briturnStatus[bulb2.id]?.on, true, "the missed light keeps its real state, not the painted one")
        XCTAssertEqual(store.briturnStatus[bulb.id]?.on, false)
    }

    func testUnverifiedIsNeverCountedAsSuccess() {
        XCTAssertFalse(OutcomeStatus.unverified("sent").isSuccess)
        XCTAssertTrue(OutcomeStatus.unverified("sent").wasSent)
        XCTAssertTrue(OutcomeStatus.confirmed.isSuccess)
        let outcomes = [DeviceOutcome(device: controller.summary(for: bulb), status: .confirmed),
                        DeviceOutcome(device: controller.summary(for: bulb2), status: .unverified("sent over Bluetooth; no advert yet"))]
        let result = CommandResult(disposition: .executed, command: .power(true), scope: .group("study"), outcomes: outcomes, pendingRequest: nil)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.spokenSummary, "Turned on 1 of 2 study lights; Front B not yet confirmed (sent over Bluetooth; no advert yet).")
    }

    func testPreCheckSkipsFreshReadingsAndRefreshesStaleOnes() async {
        bridge.onSet = { payload in ["ok": true, "dps": payload["dps"] as Any] }
        bridge.onStatus = { _ in ["ok": true, "dps": ["1": false, "2": 300]] }
        controller.config.stateFreshness = 60
        store.lastStatusAt[lamp.id] = Date()
        _ = await controller.perform(.power(true), on: DeviceQuery(text: "desk lamp"), origin: .text)
        XCTAssertEqual(bridge.commands, ["set"], "a fresh reading is not re-read")
        store.lastStatusAt[lamp.id] = Date().addingTimeInterval(-120)
        _ = await controller.perform(.power(false), on: DeviceQuery(text: "desk lamp"), origin: .text)
        XCTAssertEqual(bridge.commands.suffix(2), ["status", "set"], "a stale reading is refreshed before the write: \(bridge.commands)")
    }
}

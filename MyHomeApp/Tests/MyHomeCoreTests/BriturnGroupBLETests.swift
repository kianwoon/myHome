import Foundation
import XCTest
@testable import MyHomeCore

private final class RecordingBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String: Any]] = []
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return log }
    private func record(_ payload: [String: Any]) { lock.lock(); log.append(payload); lock.unlock() }
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        record(payload)
        return ["ok": true]
    }
}

private final class BLESends: @unchecked Sendable {
    var sent: [(key: String, on: Bool?)] = []
}

/// A Briturn group whose members are not all on the LAN: the Bluetooth-only
/// member must still be sent the command, and every outcome must be honest.
@MainActor
final class BriturnGroupBLETests: XCTestCase {
    private let bleKey = "ble-11111111-2222-3333-4444-555555555555"
    private let lanA = ControlFixtures.device("briturn-aabbccdd8e6d", name: "Front A", category: "briturn", group: "study", ip: "10.255.0.62", online: true)
    private let lanB = ControlFixtures.device("briturn-aabbccdd931d", name: "Front B", category: "briturn", group: "study", ip: "10.255.0.67", online: true)
    private let lanC = ControlFixtures.device("briturn-aabbccdd8911", name: "Back A", category: "briturn", group: "study", ip: "10.255.0.24", online: true)
    private let bluetooth = ControlFixtures.device("briturn-aabbccdd89e3", name: "Back B", category: "briturn", group: "study", ip: "", online: false)
    private var bridge: RecordingBridge!
    private var store: DeviceStore!
    private var sends: BLESends!

    private func lit(_ on: Bool) -> DeviceStore.BriturnState {
        DeviceStore.BriturnState(on: on, rawPower: on ? 0x23 : 0x24, mode: 97, r: 255, g: 200, b: 100, w: 0)
    }

    override func setUp() {
        super.setUp()
        bridge = RecordingBridge()
        store = DeviceStore(bridge: bridge, defaults: UserDefaults(suiteName: "BriturnGroupBLETests-\(UUID())")!)
        store.setRosterForTest([lanA, lanB, lanC, bluetooth])
        for device in [lanA, lanB, lanC] { store.setBriturnStatus(device.id, lit(true)) }
        sends = BLESends()
    }

    private func attachBluetooth(live: Bool = true) {
        store.bleFallbackIDs = [bluetooth.id]
        store.bleKeysByDeviceID[bluetooth.id] = [bleKey]
        store.bleLiveHook = { [bleKey] key in live && key == bleKey }
        let sends = self.sends!
        store.briturnBLESendHook = { key, on in sends.sent.append((key, on)) }
    }

    func testGroupWriteSendsTheBluetoothMemberOverBLEWithHonestOutcomes() async {
        attachBluetooth()
        XCTAssertEqual(store.reachability(for: bluetooth), .bluetooth)
        let controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 10))
        let request = CommandRequest(resolution: .briturnGroup("study", members: [lanA, lanB, lanC, bluetooth]), command: .power(true), origin: .model, confirmed: true)
        store.briturnLANReadHook = { [store] device in store.briturnStatus[device.id] }
        let result = await controller.perform(request)
        XCTAssertEqual(bridge.requests.filter { $0["cmd"] as? String == "briturnsetgroup" }.count, 0, "no group write: one write per device")
        XCTAssertEqual(bridge.requests.filter { $0["cmd"] as? String == "briturnset" }.count, 3, "each LAN member is written on its own")
        XCTAssertEqual(sends.sent.map(\.key), [bleKey], "the Bluetooth-only member gets the same command over BLE")
        XCTAssertEqual(sends.sent.first?.on, true)
        let byID = Dictionary(uniqueKeysWithValues: result.outcomes.map { ($0.device.id, $0.status) })
        XCTAssertEqual(byID[lanA.id], .confirmed)
        XCTAssertEqual(byID[bluetooth.id]?.isUnverified, true, "a Bluetooth send has no reply: never reported confirmed")
        XCTAssertEqual(store.briturnStatus[bluetooth.id]?.on, true, "optimistic paint, reconciled by the next advert")
        XCTAssertTrue(result.spokenSummary.contains("Back B not yet confirmed"), result.spokenSummary)
    }

    func testGroupWriteFailsTheBluetoothMemberWhenNoPeripheralIsLive() async {
        attachBluetooth(live: false)
        await store.setBriturnGroupState("study", on: false)
        XCTAssertEqual(bridge.requests.filter { $0["cmd"] as? String == "briturnsetgroup" }.count, 1)
        XCTAssertTrue(sends.sent.isEmpty)
        XCTAssertNotNil(store.statusErrors[bluetooth.id], "a member that could not be sent carries an error, never a silent skip")
        XCTAssertNil(store.statusErrors[lanA.id])
    }

    func testGroupWriteRefusesAMemberWithNoPathAtAll() async {
        // No BLE key, no address: nothing can carry the command.
        await store.setBriturnGroupState("study", on: true)
        XCTAssertEqual(store.statusErrors[bluetooth.id], DeviceStore.noTransportMessage)
        let controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 10))
        let result = await controller.perform(CommandRequest(resolution: .briturnGroup("study", members: [lanA, bluetooth]), command: .power(true), origin: .model, confirmed: true))
        guard case .denied = result.outcomes.first(where: { $0.device.id == bluetooth.id })?.status else {
            return XCTFail("the controller's veto must name the member: \(result.outcomes)")
        }
    }

    func testBluetoothPowerOverridesAStaleWiFiReadingWhenLANIsDown() {
        // Back B has an address but its LAN is down; the last WiFi reading said off.
        let dual = ControlFixtures.device(bluetooth.id, name: "Back B", category: "briturn", group: "study", ip: "10.255.0.64", online: false)
        store.setRosterForTest([lanA, lanB, lanC, dual])
        store.setBriturnStatus(dual.id, lit(false))
        let advert = BLELight(id: bleKey, name: "IOTWF89E3", rssi: -60)
        store.bleSeen[advert.id] = advert
        store.bleLiveHook = { [bleKey] in $0 == bleKey }
        XCTAssertEqual(store.reachability(for: dual), .bluetooth)
        let heard = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 0, g: 0, b: 0, w: 0)
        store.reconcileBLEStates([bleKey: heard], pendingIntentsOnly: false)
        XCTAssertEqual(store.power(for: dual), true, "Bluetooth is the only live path: its on/off is the truth")
        XCTAssertEqual(store.briturnStatus[dual.id]?.r, 255, "colour bytes from the advert are not trusted; the old colour stays")
        let controller = DeviceController(store: store)
        let summaries = controller.summaries()
        XCTAssertEqual(summaries.first { $0.id == dual.id }?.isOn, true)
        XCTAssertTrue(DeviceQueryAnswerer.answer(StateQuery(kind: .light, state: .on, aggregation: .count), devices: summaries).hasPrefix("4 of 4 lights are on"))
        // A light whose LAN is live keeps its WiFi reading: adverts never override it.
        let lanKey = "ble-22222222-2222-3333-4444-555555555555"
        store.bleSeen[lanKey] = BLELight(id: lanKey, name: "IOTWF8E6D", rssi: -60)
        store.bleLiveHook = { [bleKey] in $0 == bleKey || $0 == lanKey }
        store.setBriturnStatus(lanA.id, lit(false))
        store.reconcileBLEStates([lanKey: heard], pendingIntentsOnly: false)
        XCTAssertEqual(store.power(for: lanA), false)
    }

    func testUnknownStateIsCountedSeparatelyNotDropped() {
        store.setBriturnStatus(lanC.id, nil)
        let controller = DeviceController(store: store)
        let text = DeviceQueryAnswerer.answer(StateQuery(kind: .light, state: .on, aggregation: .count), devices: controller.summaries())
        XCTAssertTrue(text.contains("2 of 2 lights are on"), text)
        XCTAssertTrue(text.contains("has no state reading yet") || text.contains("have no state reading yet"), text)
        let handles = DeviceHandles(devices: controller.summaries())
        let line = HousekeeperSnapshot.line(for: controller.summary(for: lanC), handles: handles)
        XCTAssertTrue(line.contains("| ? (no reading yet) | wifi |"), line)
    }
}

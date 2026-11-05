import Foundation
import XCTest
@testable import MyHomeCore

private final class SilentBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { ["ok": true] }
}

/// Regression: a Briturn light that went Bluetooth-only (cloud offline, LAN
/// stale) kept a launch-time LAN "off" forever, so the housekeeper skipped it
/// when dimming a room although it was lit.
@MainActor
final class BluetoothOnlyStateTests: XCTestCase {
    private let bleKey = "ble-cfbf120c-0000-0000-0000-000000000001"
    private let id = "briturn-000000000001"
    private let off = DeviceStore.BriturnState(on: false, rawPower: 0x24, mode: 97, r: 0, g: 0, b: 0, w: 0)
    private let on = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 0, g: 0, b: 0, w: 128)

    private func make() -> (DeviceStore, Device) {
        let store = DeviceStore(bridge: SilentBridge(), defaults: UserDefaults(suiteName: "BTOnly-\(UUID())")!)
        let device = Device(id: id, name: "study room", ip: "192.0.2.10", version: "3.3", category: "briturn",
                            group: "study room Back", online: true)
        store.bleFallbackIDs = [id]
        store.bleKeysByDeviceID[id] = [bleKey]
        store.bleLiveHook = { $0 == self.bleKey }
        return (store, device)
    }

    func testStaleLANReadingIsUnknownOnceBluetoothOnly() {
        let (store, device) = make()
        store.applyBriturnWireState(id, off)              // launch LAN poll, cloud status not known yet
        XCTAssertEqual(store.power(for: device), false)
        store.cloudOnlineForTest(id, false)              // cloud: offline -> Bluetooth only
        XCTAssertEqual(store.reachability(for: device), .bluetooth)
        XCTAssertNil(store.power(for: device), "a pre-Bluetooth LAN reading is not a current off")
    }

    func testAdvertDecidesPowerForBluetoothOnlyLight() {
        let (store, device) = make()
        store.applyBriturnWireState(id, off)
        store.cloudOnlineForTest(id, false)
        let t0 = Date()
        store.applyBLEDerivedState(id, on, now: t0, source: bleKey, authoritativePower: true)
        XCTAssertEqual(store.power(for: device), true)
        store.pruneStaleBLEState(now: t0.addingTimeInterval(DeviceStore.bleStateMaxAge + 1))
        XCTAssertNil(store.power(for: device), "an old advert is unknown, not on/off")
    }

    func testAgreeingAdvertAttestsTheReading() {
        let (store, device) = make()
        store.applyBriturnWireState(id, off)
        store.cloudOnlineForTest(id, false)
        store.applyBLEDerivedState(id, off, source: bleKey, authoritativePower: true)
        XCTAssertEqual(store.power(for: device), false)
    }

    func testOwnWriteCountsAsCurrentReading() async {
        let (store, device) = make()
        store.cloudOnlineForTest(id, false)
        store.briturnBLESendHook = { _, _ in }
        await store.setBriturn(device, on: true)
        XCTAssertEqual(store.power(for: device), true)
    }

    func testBrightnessOnlyWriteDoesNotAttestAStaleOff() async {
        let (store, device) = make()
        store.applyBriturnWireState(id, off)
        store.cloudOnlineForTest(id, false)
        store.briturnBLESendHook = { _, _ in }
        await store.setBriturn(device, brightness: 50)
        XCTAssertNotEqual(store.power(for: device), false, "dimming must not turn a stale off into a trusted off")
    }

    func testAdvertOnBluetoothOnlyLightTakesPowerOnlyKeepingColour() {
        let (store, device) = make()
        let blue = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 0, g: 0, b: 255, w: 0)
        store.applyBriturnWireState(id, blue)
        store.cloudOnlineForTest(id, false)
        let garbage = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 12, g: 200, b: 7, w: 99)
        store.applyBLEDerivedState(id, garbage, source: bleKey, authoritativePower: true)
        store.applyBLEDerivedState(id, garbage, source: bleKey, authoritativePower: true)
        XCTAssertEqual(store.briturnStatus[id]?.b, 255, "advert colour bytes are never painted")
        XCTAssertEqual(store.power(for: device), true)
    }

    func testPowerByteIsTriState() {
        XCTAssertEqual(BLECentralCore.decodePower(0x23), true)
        XCTAssertEqual(BLECentralCore.decodePower(0x24), false)
        XCTAssertNil(BLECentralCore.decodePower(0x00))
        XCTAssertNil(BLECentralCore.decodePower(0x25))
    }

    func testSnapshotCallsUnknownBluetoothLightPossiblyOn() {
        let summary = DeviceSummary(id: id, name: "study room", room: "Study room", group: "study room Back", kind: .light,
                                    capabilities: [.power, .level], reachability: .bluetooth, isControllable: true,
                                    isOn: nil, levelPercent: nil)
        let text = HousekeeperSnapshot.stateText(summary, detail: nil)
        XCTAssertEqual(text, HousekeeperSnapshot.unknownBluetooth)
        XCTAssertFalse(text.hasPrefix("off"))
    }

    func testCountAnswerNamesGroupsNotRepeatedNames() {
        func light(_ id: String, _ group: String, on: Bool) -> DeviceSummary {
            DeviceSummary(id: id, name: "study room", room: "Study room", group: group, kind: .light, capabilities: [.power],
                          reachability: .wifi, isControllable: true, isOn: on, levelPercent: nil)
        }
        let devices = [light("a", "study room middle", on: true), light("b", "study room middle", on: true),
                       light("c", "study room Back", on: true), light("d", "study room Front", on: false)]
        let text = DeviceQueryAnswerer.answer(StateQuery(kind: .light, state: .on, aggregation: .count), devices: devices, listMax: 5)
        XCTAssertEqual(text, "3 of 4 lights are on: study room middle (2) and study room Back.")
    }
}

import Foundation
import XCTest
@testable import MyHomeCore

private final class NullBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { ["ok": true] }
}

@MainActor
final class DeviceStoreOfflineBLETests: XCTestCase {
    private let mac = "aabbccddeeff"
    private let bleKey = "ble-11111111-2222-3333-4444-555555555555"
    private func cloudLight(online: Bool) throws -> BriturnCloudDevice {
        try BriturnCloudDevice(json: ["deviceId": 7, "entityType": "TCP_WF", "productId": 95,
                                      "macAddress": mac, "name": "Lamp",
                                      "entityData": ["online": online]], homeID: 1)
    }
    private func noIPDevice(_ id: String) -> Device {
        Device(id: id, name: "Lamp", ip: "", version: "3.3", category: "briturn", group: "G", online: false)
    }
    private struct Harness { var store: DeviceStore; var device: Device; var cloudCalls: Int; var bleCalls: [String] }

    private final class Counter: @unchecked Sendable { var cloud = 0; var ble: [String] = []; var cloudOK = true }

    private func make(online: Bool, ble: Bool, cloudOK: Bool = true) throws -> (DeviceStore, Device, Counter) {
        let store = DeviceStore(bridge: NullBridge(), defaults: UserDefaults(suiteName: "OfflineBLE-\(UUID())")!)
        let item = try cloudLight(online: online)
        let device = noIPDevice(item.canonicalID)
        store.briturnCloudDevices = [item.canonicalID: item]
        if ble {
            store.bleFallbackIDs = [item.canonicalID]
            store.bleKeysByDeviceID[item.canonicalID] = [bleKey]
        }
        let counter = Counter()
        counter.cloudOK = cloudOK
        store.briturnCloudControlHook = { devices, on in
            counter.cloud += 1
            if !counter.cloudOK { throw BriturnCloudError.deviceOffline }
            let state = DeviceStore.BriturnState(on: on ?? true, rawPower: 0x23, mode: 97, r: 255, g: 255, b: 255, w: 0)
            return Dictionary(uniqueKeysWithValues: devices.map { ($0.canonicalID, state) })
        }
        store.briturnBLESendHook = { key, _ in counter.ble.append(key) }
        return (store, device, counter)
    }

    func testOfflineWithBLEGoesStraightToBLE() async throws {
        let (store, device, c) = try make(online: false, ble: true)
        await store.setBriturn(device, on: true)
        XCTAssertEqual(c.cloud, 0)
        XCTAssertEqual(c.ble, [bleKey])
        XCTAssertNil(store.statusErrors[device.id])
    }

    func testOnlineUsesCloud() async throws {
        let (store, device, c) = try make(online: true, ble: true)
        await store.setBriturn(device, on: true)
        XCTAssertEqual(c.cloud, 1)
        XCTAssertTrue(c.ble.isEmpty)
    }

    func testCloudFailureRetriesOverBLE() async throws {
        let (store, device, c) = try make(online: true, ble: true, cloudOK: false)
        await store.setBriturn(device, on: false)
        XCTAssertEqual(c.cloud, 1)
        XCTAssertEqual(c.ble, [bleKey])
        XCTAssertNil(store.statusErrors[device.id])
    }

    func testOfflineWithoutBLESurfacesError() async throws {
        let (store, device, c) = try make(online: false, ble: false, cloudOK: false)
        await store.setBriturn(device, on: true)
        XCTAssertEqual(c.cloud, 1)
        XCTAssertTrue(c.ble.isEmpty)
        XCTAssertTrue(store.statusErrors[device.id]?.hasSuffix("(Bluetooth not in range for this light.)") == true)
    }

    func testLiveCandidateKeyIsUsed() async throws {
        let (store, device, c) = try make(online: false, ble: true)
        store.bleKeysByDeviceID[device.id] = ["ble-aaaaaaaa-0000-0000-0000-000000000001", "ble-cfbf120c-7f3d-b4f1-8827-906f05c07e79"]
        store.bleLiveHook = { $0 == "ble-cfbf120c-7f3d-b4f1-8827-906f05c07e79" }
        await store.setBriturn(device, on: true)
        XCTAssertEqual(c.ble, ["ble-cfbf120c-7f3d-b4f1-8827-906f05c07e79"])
        XCTAssertNil(store.statusErrors[device.id])
    }

    func testNoLiveCandidateSurfacesErrorAndRollsBack() async throws {
        let (store, device, c) = try make(online: false, ble: true)
        store.bleKeysByDeviceID[device.id] = ["ble-aaaaaaaa-0000-0000-0000-000000000001", "ble-cfbf120c-7f3d-b4f1-8827-906f05c07e79"]
        store.bleLiveHook = { _ in false }
        store.bleDiagnosticsHook = BLEDiagnostics()
        await store.setBriturn(device, on: true)
        XCTAssertTrue(c.ble.isEmpty)
        XCTAssertEqual(store.statusErrors[device.id], BLEReason.permissionPending)
        XCTAssertNil(store.briturnStatus[device.id], "optimistic state must not stick")
    }

    func testGroupOfflineMemberGoesOverBLEOnlineStaysOnCloud() async throws {
        let (store, offline, c) = try make(online: false, ble: true)
        var onlineItem = try BriturnCloudDevice(json: ["deviceId": 8, "entityType": "TCP_WF", "productId": 95,
                                                       "macAddress": "112233445566", "name": "B",
                                                       "entityData": ["online": true]], homeID: 1)
        onlineItem.groupName = "G"
        let onlineDev = noIPDevice(onlineItem.canonicalID)
        store.briturnCloudDevices[onlineItem.canonicalID] = onlineItem
        _ = onlineDev
        store.rebuildBriturnRoster()
        var offlineItem = store.briturnCloudDevices[offline.id]!
        offlineItem.groupName = "G"
        store.briturnCloudDevices[offline.id] = offlineItem
        store.rebuildBriturnRoster()
        var cloudIDs: [String] = []
        let base = store.briturnCloudControlHook!
        store.briturnCloudControlHook = { devices, on in cloudIDs = devices.map(\.canonicalID); return try await base(devices, on) }
        await store.setBriturnGroupState("G", on: true)
        XCTAssertEqual(cloudIDs, [onlineItem.canonicalID])
        XCTAssertEqual(c.ble, [bleKey])
    }

    // MARK: - Reachability and BLE-derived state

    func testReachabilityBluetoothWhenCloudOfflineButBLELive() throws {
        let (store, device, _) = try make(online: false, ble: true)
        store.bleLiveHook = { $0 == self.bleKey }
        XCTAssertEqual(store.reachability(for: device), .bluetooth)
    }

    func testReachabilityOfflineOnlyWithoutAnyPath() throws {
        let (store, device, _) = try make(online: false, ble: true)
        store.bleLiveHook = { _ in false }
        XCTAssertEqual(store.reachability(for: device), .offline)
    }

    func testReachabilityCloudAndWiFi() throws {
        let (store, device, _) = try make(online: true, ble: true)
        store.bleLiveHook = { _ in true }
        XCTAssertEqual(store.reachability(for: device), .cloud)
        let lan = Device(id: device.id, name: "Lamp", ip: "192.168.1.9", version: "3.3",
                         category: "briturn", group: "G", online: true)
        XCTAssertEqual(store.reachability(for: lan), .wifi)
    }

    func testBLEStateFillsNilStatusThenGoesStale() throws {
        let (store, device, _) = try make(online: false, ble: true)
        let state = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 0, g: 0, b: 0, w: 128)
        let t0 = Date()
        store.applyBLEDerivedState(device.id, state, now: t0)
        XCTAssertEqual(store.briturnStatus[device.id], state)
        store.pruneStaleBLEState(now: t0.addingTimeInterval(DeviceStore.bleStateMaxAge - 1))
        XCTAssertNotNil(store.briturnStatus[device.id])
        store.pruneStaleBLEState(now: t0.addingTimeInterval(DeviceStore.bleStateMaxAge + 1))
        XCTAssertNil(store.briturnStatus[device.id])
    }

    func testBLEStateNeverOverridesWireStatus() async throws {
        let (store, device, _) = try make(online: true, ble: true)
        await store.setBriturn(device, on: true)   // cloud hook paints a state
        let wire = store.briturnStatus[device.id]
        XCTAssertNotNil(wire)
        store.applyBLEDerivedState(device.id, DeviceStore.BriturnState(on: false, rawPower: 0x24, mode: 97, r: 0, g: 0, b: 0, w: 0))
        XCTAssertEqual(store.briturnStatus[device.id], wire)
    }
}

@MainActor
final class DeviceStoreControllableTests: XCTestCase {
    private func light(ip: String = "") -> Device {
        Device(id: "x", name: "Lamp", ip: ip, version: "3.3", category: "briturn", group: "G", online: false)
    }
    private func store() -> DeviceStore {
        DeviceStore(bridge: NullBridge(), defaults: UserDefaults(suiteName: "Controllable-\(UUID())")!)
    }

    func testNoPathIsNotControllable() {
        XCTAssertFalse(store().isControllable(for: light()))
    }

    func testBluetoothFallbackIsControllable() {
        let s = store()
        s.bleFallbackIDs = ["x"]
        XCTAssertTrue(s.isControllable(for: light()))
    }

    func testAddressIsControllable() {
        XCTAssertTrue(store().isControllable(for: light(ip: "192.168.1.5")))
    }
}

import Foundation
import XCTest
@testable import MyHomeCore

/// Records every bridge command so a test can prove the bridge was skipped.
private final class RecordingBridge: BridgeSending, @unchecked Sendable {
    var cmds: [String] = []
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        cmds.append(payload["cmd"] as? String ?? "")
        return ["ok": false, "error": "unreachable"]
    }
}

/// Regressions for the "study room" light: a stale LAN IP, cloud offline and a
/// live Bluetooth advert. Writes must go over BLE first, and a brightness-only
/// write must paint the new brightness (no BLE readback ever corrects it).
@MainActor
final class BriturnStaleLANRoutingTests: XCTestCase {
    private let mac = "aabbccddeeff"
    private let bleKey = "ble-11111111-2222-3333-4444-555555555555"
    private final class Counter: @unchecked Sendable { var cloud = 0; var ble: [String] = [] }

    private func make(prev: DeviceStore.BriturnState?) throws -> (DeviceStore, Device, Counter, RecordingBridge) {
        let bridge = RecordingBridge()
        let store = DeviceStore(bridge: bridge, defaults: UserDefaults(suiteName: "StaleLAN-\(UUID())")!)
        let item = try BriturnCloudDevice(json: ["deviceId": 7, "entityType": "TCP_WF", "productId": 95,
                                                 "macAddress": mac, "name": "Lamp",
                                                 "entityData": ["online": false]], homeID: 1)
        let id = item.canonicalID
        store.briturnCloudDevices = [id: item]
        store.bleFallbackIDs = [id]
        store.bleKeysByDeviceID[id] = [bleKey]
        store.cloudOnlineForTest(id, false)
        let counter = Counter()
        store.briturnCloudControlHook = { _, _ in counter.cloud += 1; throw BriturnCloudError.deviceOffline }
        store.briturnBLESendHook = { key, _ in counter.ble.append(key) }
        store.bleLiveHook = { $0 == self.bleKey }
        if let prev { store.setBriturnStatus(id, prev) }
        let device = Device(id: id, name: "Lamp", ip: "192.168.5.80", version: "3.3",
                            category: "briturn", group: "G", online: true)
        return (store, device, counter, bridge)
    }

    func testStaleLANWithLiveBLESkipsBridgeAndCloud() async throws {
        let (store, device, c, bridge) = try make(prev: nil)
        XCTAssertEqual(store.reachability(for: device), .bluetooth)
        let ack = await store.setBriturn(device, brightness: 40)
        XCTAssertEqual(ack, .sent)
        XCTAssertEqual(c.ble, [bleKey])
        XCTAssertEqual(c.cloud, 0, "cloud is offline: no detour")
        XCTAssertFalse(bridge.cmds.contains("briturnset"), "stale LAN: no bridge detour")
    }

    func testLANStillUsedWithoutBLEEvidence() async throws {
        let (store, device, c, bridge) = try make(prev: nil)
        store.bleLiveHook = { _ in false }
        store.briturnBLESendHook = nil
        XCTAssertEqual(store.reachability(for: device), .wifi)
        await store.setBriturn(device, brightness: 40)
        XCTAssertTrue(bridge.cmds.contains("briturnset"))
        XCTAssertTrue(c.ble.isEmpty)
    }

    func testBLEBrightnessOnlyPaintsScaledPeak() async throws {
        let prev = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 186, g: 93, b: 0, w: 0)
        let (store, device, _, _) = try make(prev: prev)
        await store.setBriturn(device, brightness: 100)
        let full = try XCTUnwrap(store.briturnStatus[device.id])
        XCTAssertEqual(max(full.r, full.g, full.b), 255, "card must show 100, not the old 73")
        XCTAssertEqual(Double(full.g), 127.5, accuracy: 1, "hue kept: channels scale together")
        await store.setBriturn(device, brightness: 50)
        let half = try XCTUnwrap(store.briturnStatus[device.id])
        XCTAssertEqual(max(half.r, half.g, half.b), 128)
    }

    func testScaledHelperUsesOwnPeak() {
        let a = DeviceStore.briturnScaled((r: 176, g: 0, b: 0), toPercent: 100)
        let b = DeviceStore.briturnScaled((r: 0, g: 186, b: 93), toPercent: 100)
        XCTAssertEqual(max(a.r, a.g, a.b), max(b.r, b.g, b.b), "members with different peaks align")
        XCTAssertEqual(DeviceStore.briturnScaled((r: 0, g: 0, b: 0), toPercent: 60).r, 0)
    }

    func testGroupBLEMemberBrightnessPaintsNewValue() async throws {
        let prev = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 186, g: 0, b: 0, w: 0)
        let (store, device, c, _) = try make(prev: prev)
        var item = store.briturnCloudDevices[device.id]!
        item.groupName = "G"
        store.briturnCloudDevices[device.id] = item
        store.rebuildBriturnRoster()
        store.setBriturnStatus(device.id, prev)
        let member = try XCTUnwrap(store.members(of: "G").first)
        await store.setBriturnGroupState("G", brightness: 100)
        XCTAssertEqual(c.ble, [bleKey])
        XCTAssertEqual(store.briturnStatus[member.id]?.r, 255)
    }

    func testCloudWriteDropsPollThatStartedBeforeIt() async throws {
        let (store, device, _, _) = try make(prev: nil)
        let pollStart = Date().addingTimeInterval(-1)
        store.cloudOnlineForTest(device.id, true)
        store.briturnCloudControlHook = { devices, _ in
            let s = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 255, g: 0, b: 0, w: 0)
            return Dictionary(uniqueKeysWithValues: devices.map { ($0.canonicalID, s) })
        }
        let noIP = Device(id: device.id, name: "Lamp", ip: "", version: "3.3", category: "briturn", group: "G", online: false)
        await store.setBriturn(noIP, brightness: 100)
        let old = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 176, g: 0, b: 0, w: 0)
        store.applyBriturnWireStates([device.id: old], readStartedAt: pollStart)
        XCTAssertEqual(store.briturnStatus[device.id]?.r, 255, "pre-write poll must not repaint the old value")
    }
}

import Foundation
import XCTest
@testable import MyHomeCore

private final class RecordingBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String: Any]] = []
    var ok = true
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return log }
    private func record(_ payload: [String: Any]) { lock.lock(); log.append(payload); lock.unlock() }
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        record(payload)
        return ["ok": ok]
    }
}

@MainActor
final class DeviceStoreGroupMirrorTests: XCTestCase {
    private func cloud(mac: String, group: String?) throws -> BriturnCloudDevice {
        var device = try BriturnCloudDevice(json: ["deviceId": 7, "entityType": "TCP_WF", "productId": 95,
                                                   "macAddress": mac, "name": "Lamp",
                                                   "entityData": ["online": true]], homeID: 1)
        device.groupName = group
        return device
    }
    private func local(_ id: String, group: String?) -> Device {
        Device(id: id, name: "Lamp", ip: "192.168.1.5", version: "3.3", category: "briturn", group: group, online: true)
    }
    private func makeStore(_ bridge: RecordingBridge) -> DeviceStore {
        DeviceStore(bridge: bridge, defaults: UserDefaults(suiteName: "DeviceStoreGroupMirrorTests-\(UUID())")!)
    }

    func testDifferingGroupIsPushedAndRosterUpdated() async throws {
        let bridge = RecordingBridge()
        let store = makeStore(bridge)
        let item = try cloud(mac: "aabbccddeeff", group: "Study")
        store.briturnCloudDevices = [item.canonicalID: item]
        store.bridgeRoster = [local(item.canonicalID, group: "study room - Front")]
        await store.mirrorCloudGroupsToBridge()
        XCTAssertEqual(bridge.requests.count, 1)
        XCTAssertEqual(bridge.requests.first?["cmd"] as? String, "briturngroup")
        XCTAssertEqual(bridge.requests.first?["id"] as? String, item.canonicalID)
        XCTAssertEqual(bridge.requests.first?["group"] as? String, "Study")
        XCTAssertEqual(store.bridgeRoster.first?.group, "Study")
        XCTAssertEqual(store.roster.first?.group, "Study")
        await store.mirrorCloudGroupsToBridge()
        XCTAssertEqual(bridge.requests.count, 1, "no request once equal")
    }

    func testEqualOrUngroupedCloudSendsNothing() async throws {
        let bridge = RecordingBridge()
        let store = makeStore(bridge)
        let a = try cloud(mac: "aabbccddeeff", group: "Study")
        store.briturnCloudDevices = [a.canonicalID: a]
        store.bridgeRoster = [local(a.canonicalID, group: "Study")]
        await store.mirrorCloudGroupsToBridge()
        let b = try cloud(mac: "112233445566", group: nil)
        store.briturnCloudDevices = [b.canonicalID: b]
        store.bridgeRoster = [local(b.canonicalID, group: "guess 1")]
        await store.mirrorCloudGroupsToBridge()
        XCTAssertTrue(bridge.requests.isEmpty)
    }

    func testFailedPushLeavesRosterForRetry() async throws {
        let bridge = RecordingBridge()
        bridge.ok = false
        let store = makeStore(bridge)
        let item = try cloud(mac: "aabbccddeeff", group: "Study")
        store.briturnCloudDevices = [item.canonicalID: item]
        store.bridgeRoster = [local(item.canonicalID, group: "old")]
        await store.mirrorCloudGroupsToBridge()
        XCTAssertEqual(store.bridgeRoster.first?.group, "old")
        bridge.ok = true
        await store.mirrorCloudGroupsToBridge()
        XCTAssertEqual(bridge.requests.count, 2)
        XCTAssertEqual(store.bridgeRoster.first?.group, "Study")
    }

    func testBLEReattachedWhenRosterGainsCloudLight() async throws {
        let store = makeStore(RecordingBridge())
        let light = BLELight(id: "ble-0865f0ef87bf", name: "IOTWFXXXX", rssi: -50)
        store.bleSeen[light.id] = light
        XCTAssertNil(store.bleKeysByDeviceID["briturn-0865f0ef87bf"])
        let item = try cloud(mac: "0865f0ef87bf", group: nil)
        store.briturnCloudDevices = [item.canonicalID: item]
        store.reattachBLETransports()
        XCTAssertNil(store.bleKeysByDeviceID["briturn-0865f0ef87bf"], "roster has no cloud card yet")
        // A bridge-known light with a differing cloud group forces a roster rebuild, which adds the cloud-only card.
        let other = try cloud(mac: "aabbccddeeff", group: "G")
        store.briturnCloudDevices[other.canonicalID] = other
        store.bridgeRoster = [local(other.canonicalID, group: nil)]
        await store.mirrorCloudGroupsToBridge()
        XCTAssertEqual(store.bleKeysByDeviceID["briturn-0865f0ef87bf"], ["ble-0865f0ef87bf"])
        XCTAssertTrue(store.bleFallbackIDs.contains("briturn-0865f0ef87bf"))
    }

    func testProbeGatedByEnvironment() {
        XCTAssertFalse(DeviceStore.briturnProbeEnabled(environment: [:]))
        XCTAssertFalse(DeviceStore.briturnProbeEnabled(environment: [DeviceStore.briturnProbeEnvVar: "0"]))
        XCTAssertTrue(DeviceStore.briturnProbeEnabled(environment: [DeviceStore.briturnProbeEnvVar: "1"]))
    }
}

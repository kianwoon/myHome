import Combine
import Foundation
import XCTest
@testable import MyHomeCore

private final class NullBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { ["ok": true] }
}

/// Zengge advert payload (state at byte 14: power 0x23, white sub-mode).
private let mfrOn = Data([0x5A, 0x00, 0x64, 0x1D, 0xF0, 0x50, 0x01, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                          0x23, 0x61, 0x0F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
private let mfrOff: Data = {
    var d = mfrOn
    d[14] = 0x24
    return d
}()

private final class FlushLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BLEFlush] = []
    func add(_ f: BLEFlush) { lock.lock(); items.append(f); lock.unlock() }
    var all: [BLEFlush] { lock.lock(); defer { lock.unlock() }; return items }
}

final class BLECoalescingTests: XCTestCase {
    private func wait(_ seconds: TimeInterval) {
        let done = expectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    func testAdvertBurstIsOneFlushAndUnchangedAdvertsCarryNoData() {
        let core = BLECentralCore(startCentral: false, summaryInterval: BLEManager.summaryInterval)
        let log = FlushLog()
        core.onFlush = { log.add($0) }
        let uuid = UUID()
        core.queue.async {
            for rssi in -90 ..< -40 {   // rssi churn must not publish
                core.ingestAccepted(uuid: uuid, peripheral: nil, name: "IOTWF4F1", rssi: rssi,
                                    mfr: mfrOn, hasServiceData: false)
            }
        }
        wait(BLECentralCore.publishInterval * 3)
        XCTAssertEqual(log.all.count, 1, "a burst within one interval coalesces into one batch")
        XCTAssertEqual(log.all.first?.lights?.count, 1)
        XCTAssertEqual(log.all.first?.lights?.first?.rssi, -90, "rssi frozen at first sight")
        XCTAssertEqual(log.all.first?.states?.count, 1)
        XCTAssertTrue(core.hasPeripheral(id: BLECentralCore.lightID(for: uuid)))
        XCTAssertNotNil(core.lastAdvert(for: BLECentralCore.lightID(for: uuid)))

        core.queue.async {
            core.ingestAccepted(uuid: uuid, peripheral: nil, name: "IOTWF4F1", rssi: -50, mfr: mfrOn, hasServiceData: false)
        }
        wait(BLECentralCore.publishInterval * 3)
        XCTAssertEqual(log.all.count, 2, "still ticks while adverts are heard")
        XCTAssertNil(log.all.last?.lights)
        XCTAssertNil(log.all.last?.states, "identical advert: no state in the batch")

        core.queue.async {
            core.ingestAccepted(uuid: uuid, peripheral: nil, name: "IOTWF4F1", rssi: -50, mfr: mfrOff, hasServiceData: false)
        }
        wait(BLECentralCore.publishInterval * 3)
        XCTAssertEqual(log.all.last?.states?.values.first?.on, false)
    }

    @MainActor
    func testManagerPublishesStatesOnlyOnChange() {
        let ble = BLEManager(startCentral: false)
        var emissions = 0
        let sub = ble.$states.dropFirst().sink { _ in emissions += 1 }
        let uuid = UUID()
        ble.noteLight(uuid: uuid, name: "IOTWF4F1", rssi: -50, mfr: mfrOn, hasServiceData: false)
        ble.noteLight(uuid: uuid, name: "IOTWF4F1", rssi: -40, mfr: mfrOn, hasServiceData: false)
        XCTAssertEqual(emissions, 1)
        ble.noteLight(uuid: uuid, name: "IOTWF4F1", rssi: -40, mfr: mfrOff, hasServiceData: false)
        XCTAssertEqual(emissions, 2)
        sub.cancel()
    }
}

@MainActor
final class DeviceStoreRepublishTests: XCTestCase {
    private func store() -> DeviceStore {
        DeviceStore(bridge: NullBridge(), defaults: UserDefaults(suiteName: "Republish-\(UUID())")!)
    }
    private let state = DeviceStore.BriturnState(on: true, rawPower: 0x23, mode: 97, r: 0, g: 0, b: 0, w: 128)

    func testEqualBLEStateDoesNotRepublish() {
        let store = store()
        var changes = 0
        let sub = store.objectWillChange.sink { changes += 1 }
        store.applyBLEDerivedState("ble-x", state)
        store.applyBLEDerivedState("ble-x", state)
        XCTAssertEqual(changes, 1)
        store.pruneStaleBLEState()   // fresh: nothing to drop
        store.setBriturnStatus("absent", nil)
        XCTAssertEqual(changes, 1, "nil over an absent key must not publish")
        sub.cancel()
    }

    func testPruneKeepsLightWhoseAdvertsAreStillHeard() {
        let store = store()
        let t0 = Date()
        let later = t0.addingTimeInterval(DeviceStore.bleStateMaxAge + 1)
        store.applyBLEDerivedState("ble-x", state, now: t0, source: "ble-x")
        store.bleLastAdvertHook = { _ in later }
        store.pruneStaleBLEState(now: later)
        XCTAssertEqual(store.briturnStatus["ble-x"], state, "unchanged adverts still count as fresh")
        store.bleLastAdvertHook = { _ in t0 }
        store.pruneStaleBLEState(now: later)
        XCTAssertNil(store.briturnStatus["ble-x"])
    }

    func testTickOnlyRevisitsPendingIntents() {
        let store = store()
        var changes = 0
        let light = BLELight(id: "ble-00000000-0000-0000-0000-000000000001", name: "IOTWF001", rssi: -50)
        store.bleSeen[light.id] = light
        let sub = store.objectWillChange.sink { changes += 1 }
        store.reconcileBLEStates([light.id: state], pendingIntentsOnly: true)
        XCTAssertEqual(changes, 0)
        XCTAssertNil(store.briturnStatus[light.id])
        store.reconcileBLEStates([light.id: state], pendingIntentsOnly: false)
        XCTAssertEqual(store.briturnStatus[light.id], state)
        sub.cancel()
    }
}

@MainActor
final class DeviceStoreDerivedCacheTests: XCTestCase {
    private func spec(_ json: String) throws -> [String: DPDeclaration] {
        try JSONDecoder().decode([String: DPDeclaration].self, from: Data(json.utf8))
    }
    private func fan(_ spec: [String: DPDeclaration]) -> Device {
        Device(id: "fan1", name: "Fan", ip: "10.0.0.2", version: "3.3", category: "fs", online: true, spec: spec)
    }

    func testCapabilitiesBuiltOncePerSpecAndOnRosterRebuild() throws {
        let store = DeviceStore(bridge: NullBridge(), defaults: UserDefaults(suiteName: "Cache-\(UUID())")!)
        let a = try spec(#"{"10":{"code":"b","type":"Boolean"},"2":{"code":"a","type":"Boolean"}}"#)
        let device = fan(a)
        let first = store.state(for: device).capabilities.map(\.dpId)
        _ = store.state(for: device)
        _ = store.state(for: device)
        XCTAssertEqual(first, ["2", "10"], "numeric dp order kept")
        XCTAssertEqual(store.derivedCaches.capabilityBuilds, 1)

        let b = try spec(#"{"3":{"code":"c","type":"Boolean"}}"#)
        XCTAssertEqual(store.state(for: fan(b)).capabilities.map(\.dpId), ["3"], "spec change rebuilds")
        XCTAssertEqual(store.derivedCaches.capabilityBuilds, 2)

        store.setRosterForTest([fan(b)])
        _ = store.state(for: fan(b))
        XCTAssertEqual(store.derivedCaches.capabilityBuilds, 3, "roster rebuild invalidates")
    }

    func testDevicesAndLivenessMemoInvalidateOnInputs() {
        let store = DeviceStore(bridge: NullBridge(), defaults: UserDefaults(suiteName: "Cache-\(UUID())")!)
        let lamp = Device(id: "briturn-0865f0ef8577", name: "Lamp", ip: "", version: "Cloud", category: "briturn", online: false)
        store.setRosterForTest([lamp])
        XCTAssertEqual(store.devices.map(\.id), [lamp.id])
        let light = BLELight(id: "ble-00000000-0000-0000-0000-000000000002", name: "IOTWF123", rssi: -50)
        store.bleSeen[light.id] = light
        XCTAssertEqual(store.devices.map(\.id), [lamp.id, light.id], "new BLE-only light appears")
        store.bleKeysByDeviceID[lamp.id] = [light.id]
        store.bleLiveHook = { _ in false }
        XCTAssertFalse(store.isBLELive(for: lamp))
        store.bleLiveHook = { $0 == light.id }
        XCTAssertTrue(store.isBLELive(for: lamp), "hook change invalidates the liveness memo")
    }
}

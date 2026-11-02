import Combine
import Foundation
import XCTest
@testable import MyHomeCore

/// Answers every `status` with fixed dps after an optional delay; counts calls per id.
private final class StatusBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    let delay: TimeInterval
    init(delay: TimeInterval = 0) { self.delay = delay }
    var total: Int { lock.lock(); defer { lock.unlock() }; return calls.values.reduce(0, +) }
    func count(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return calls[id] ?? 0 }
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard payload["cmd"] as? String == "status", let id = payload["id"] as? String else { return ["ok": true] }
        lock.withLock { calls[id, default: 0] += 1 }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return ["ok": true, "dps": ["1": true, "3": 2]]
    }
}

@MainActor
final class DeviceStoreSweepTests: XCTestCase {
    private func makeStore(_ bridge: StatusBridge, plugs: Int) -> DeviceStore {
        let store = DeviceStore(bridge: bridge, defaults: UserDefaults(suiteName: "DeviceStoreSweepTests-\(UUID())")!)
        store.bridgeRoster = (0..<plugs).map {
            Device(id: "plug\($0)", name: "Plug \($0)", ip: "192.168.1.\(10 + $0)", version: "3.3",
                   category: "cz", group: nil, online: true)
        }
        store.rebuildBriturnRoster()
        return store
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Publishes attributable to a status sweep (the shared BLE manager may
    /// publish unrelated properties concurrently in the full suite).
    private static let sweepProperties: Set<String> = ["dpsById", "isOn", "statusViaCloud", "statusErrors",
                                                        "statusLoading", "cloudOnline"]

    private func sweepPublishes(_ store: DeviceStore) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: store.publishMeter.drain().top.filter { Self.sweepProperties.contains($0.0) })
    }

    func testUnchangedSweepPublishesNothing() async {
        let bridge = StatusBridge()
        let store = makeStore(bridge, plugs: 4)
        await store.refreshTuyaStatuses(scope: "test")
        XCTAssertEqual(store.power(for: store.devices[0]), true)
        _ = store.publishMeter.drain()
        await store.refreshTuyaStatuses(scope: "test")
        XCTAssertEqual(bridge.total, 8)
        XCTAssertEqual(sweepPublishes(store), [:], "a sweep that reads the same dps must not invalidate the cards")
    }

    func testFirstSweepIsOneWritePerCollection() async {
        let store = makeStore(StatusBridge(), plugs: 5)
        _ = store.publishMeter.drain()
        await store.refreshTuyaStatuses(scope: "test")
        // One write each for dpsById, isOn, statusViaCloud; statusErrors is
        // unchanged (empty) and bulk sweeps never touch statusLoading.
        XCTAssertEqual(sweepPublishes(store), ["dpsById": 1, "isOn": 1, "statusViaCloud": 1])
    }

    func testTuyaSweepRunsConcurrently() async {
        let delay = 0.3
        let bridge = StatusBridge(delay: delay)
        let store = makeStore(bridge, plugs: DeviceStore.tuyaSweepWidth)
        let started = Date()
        await store.loadAllStatuses()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(bridge.total, DeviceStore.tuyaSweepWidth)
        XCTAssertLessThan(elapsed, delay * 3, "devices must overlap, not walk one at a time")
    }

    func testSwitchRefreshesOnlyStaleVisibleDevicesInBackground() async {
        let bridge = StatusBridge()
        let store = makeStore(bridge, plugs: 3)
        await store.refreshTuyaStatuses(scope: "test")
        XCTAssertEqual(bridge.total, 3)

        store.dashboardDidSwitch(scope: "test", visible: store.devices)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(bridge.total, 3, "fresh devices are not re-read on a switch")

        store.lastStatusAt["plug1"] = Date().addingTimeInterval(-DeviceStore.switchRefreshMinAge - 1)
        store.dashboardDidSwitch(scope: "test", visible: store.devices)
        await waitUntil { bridge.count("plug1") == 2 }
        XCTAssertEqual(bridge.count("plug1"), 2)
        XCTAssertEqual(bridge.count("plug0"), 1)
        XCTAssertEqual(bridge.count("plug2"), 1)

        // A hidden device is never refreshed by a switch, however stale.
        store.lastStatusAt["plug2"] = .distantPast
        store.dashboardDidSwitch(scope: "test", visible: [store.devices[0]])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(bridge.count("plug2"), 1)
    }

    func testOverlappingReadsOfOneDeviceDeduplicate() async {
        let bridge = StatusBridge(delay: 0.2)
        let store = makeStore(bridge, plugs: 2)
        async let sweep: Void = store.refreshTuyaStatuses(scope: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)
        await store.loadStatus(for: store.devices[0], force: true)
        await store.refreshTuyaStatuses(scope: "test-overlap")
        await sweep
        XCTAssertEqual(bridge.count("plug0"), 1, "an in-flight read is never doubled")
        XCTAssertEqual(bridge.count("plug1"), 1)
    }

    func testLANBackoffAfterRepeatedFailuresAndResetOnSuccess() {
        let store = makeStore(StatusBridge(), plugs: 0)
        let now = Date()
        for _ in 0..<(DeviceStore.lanFailStreakThreshold - 1) { store.noteLANResult("lamp", ok: false) }
        XCTAssertFalse(store.lanBackedOff("lamp", now: now))
        store.noteLANResult("lamp", ok: false)
        XCTAssertTrue(store.lanBackedOff("lamp", now: Date()))
        XCTAssertFalse(store.lanBackedOff("lamp", now: Date().addingTimeInterval(DeviceStore.lanBackoffInterval + 1)))
        store.noteLANResult("lamp", ok: true)
        XCTAssertFalse(store.lanBackedOff("lamp", now: Date()))
    }

    func testPublishMeterAttributesByProperty() async {
        let store = makeStore(StatusBridge(), plugs: 2)
        _ = store.publishMeter.drain()
        await store.refreshTuyaStatuses(scope: "test")
        let (total, top) = store.publishMeter.drain()
        XCTAssertGreaterThan(total, 0)
        let names = Set(top.map(\.0))
        XCTAssertTrue(names.contains("dpsById"))
        XCTAssertTrue(names.contains("isOn"))
        XCTAssertEqual(store.publishMeter.drain().total, 0, "drain clears the window")
    }
}

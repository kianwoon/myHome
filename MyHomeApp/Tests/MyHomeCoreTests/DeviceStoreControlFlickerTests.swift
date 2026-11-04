import Foundation
import XCTest
@testable import MyHomeCore

private final class NullBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { ["ok": true] }
}

/// A control must move once and stay put: stale reads (started before the
/// command, or echoing the old value after the first confirmation) never
/// repaint the previous value.
@MainActor
final class DeviceStoreControlFlickerTests: XCTestCase {
    private func makeStore() -> DeviceStore {
        DeviceStore(bridge: NullBridge(), defaults: UserDefaults(suiteName: "ControlFlicker-\(UUID())")!)
    }

    func testPollStartedBeforeCommandIsDropped() async {
        let store = makeStore()
        let pollStarted = Date()
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.lastUserWriteAt["plug"] = Date()
        store.dpsById["plug"] = ["1": .bool(true)]
        store.applyPollBatch(dps: ["plug": ["1": .bool(false)]], viaCloud: [:], errors: [:], readStartedAt: pollStarted)
        XCTAssertEqual(store.dpsById["plug"]?["1"], .bool(true))
    }

    func testPollStartedAfterCommandIsApplied() async {
        let store = makeStore()
        store.lastUserWriteAt["plug"] = Date()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let pollStarted = Date()
        store.applyPollBatch(dps: ["plug": ["1": .bool(false)]], viaCloud: [:], errors: [:], readStartedAt: pollStarted)
        XCTAssertEqual(store.dpsById["plug"]?["1"], .bool(false))
    }

    func testConfirmedValueStaysDefendedAgainstLaggingEcho() async {
        let store = makeStore()
        let device = Device(id: "plug", name: "Plug", ip: "10.0.0.2", version: "3.3",
                            category: "cz", group: nil, online: true)
        await store.setDps(device, ["1": true], optimistic: ["1": .bool(true)])
        // Device confirms, then a lagging cloud echoes the old value.
        XCTAssertEqual(store.reconciled("plug", ["1": .bool(true)])["1"], .bool(true))
        XCTAssertEqual(store.reconciled("plug", ["1": .bool(false)])["1"], .bool(true))
    }
}

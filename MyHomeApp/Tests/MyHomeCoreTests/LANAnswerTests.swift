import Foundation
import XCTest
@testable import MyHomeCore

/// Answers every `status` with fixed dps, tagged with `via` when set.
private final class ViaBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private var viaTag: String?
    private var fail = false
    func set(via: String?, fail: Bool = false) { lock.withLock { viaTag = via; self.fail = fail } }
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard payload["cmd"] as? String == "status" else { return ["ok": true] }
        let (via, fail) = lock.withLock { (viaTag, self.fail) }
        if fail { return ["ok": false, "error": "no response"] }
        var reply: [String: Any] = ["ok": true, "dps": ["1": true]]
        if let via { reply["via"] = via }
        return reply
    }
}

@MainActor
final class LANAnswerTests: XCTestCase {
    func testAnyNonEmptyViaTagIsRemote() {
        let cases: [(Any?, Bool)] = [("cloud", true), ("appapi", true), (nil, false), ("", false), (NSNull(), false)]
        for (via, expected) in cases {
            XCTAssertEqual(DeviceStore.isRemoteVia(via), expected, "via=\(String(describing: via))")
        }
    }

    func testLANAnswerOutranksStaleOrPendingCloudFlag() {
        XCTAssertTrue(DeviceStore.badgeShowsLAN(cloud: false, lanAnswered: true))
        XCTAssertTrue(DeviceStore.badgeShowsLAN(cloud: nil, lanAnswered: true))
        XCTAssertFalse(DeviceStore.badgeShowsLAN(cloud: true, lanAnswered: true), "cloud online keeps its own badge")
        XCTAssertFalse(DeviceStore.badgeShowsLAN(cloud: false, lanAnswered: false))
        XCTAssertFalse(DeviceStore.badgeShowsLAN(cloud: nil, lanAnswered: false))
    }

    private func makeStore(_ bridge: ViaBridge, category: String = "cz") -> (DeviceStore, Device) {
        let store = DeviceStore(bridge: bridge, defaults: UserDefaults(suiteName: "LANAnswerTests-\(UUID())")!)
        let device = Device(id: "plug0", name: "Plug", ip: "192.168.1.10", version: "3.3",
                            category: category, group: nil, online: true)
        store.bridgeRoster = [device]
        store.rebuildBriturnRoster()
        return (store, device)
    }

    func testDirectAnswerCountsAsLAN() async {
        let bridge = ViaBridge()
        let (store, device) = makeStore(bridge)
        store.cloudOnline[device.id] = false
        await store.refreshTuyaStatuses(scope: "test")
        XCTAssertEqual(store.statusViaCloud[device.id], false)
        XCTAssertTrue(store.answeredOnLAN(device))
    }

    func testAppAPIReadIsNotLAN() async {
        let bridge = ViaBridge()
        bridge.set(via: "appapi")
        let (store, device) = makeStore(bridge)
        await store.refreshTuyaStatuses(scope: "test")
        XCTAssertEqual(store.statusViaCloud[device.id], true)
        XCTAssertFalse(store.answeredOnLAN(device))
    }

    func testFailedReadAfterLANAnswerIsNotLAN() async {
        let bridge = ViaBridge()
        let (store, device) = makeStore(bridge)
        await store.refreshTuyaStatuses(scope: "test")
        XCTAssertTrue(store.answeredOnLAN(device))
        bridge.set(via: nil, fail: true)
        await store.refreshTuyaStatuses(scope: "test")
        XCTAssertFalse(store.answeredOnLAN(device))
    }

    func testBriturnNeverUsesLANAnswer() {
        let (store, device) = makeStore(ViaBridge(), category: "briturn")
        store.statusViaCloud[device.id] = false
        XCTAssertFalse(store.answeredOnLAN(device), "Briturn badge follows reachability(for:)")
    }
}

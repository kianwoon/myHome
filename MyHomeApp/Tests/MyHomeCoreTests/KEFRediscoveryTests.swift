import XCTest
@testable import MyHomeCore

/// A saved speaker that stops answering is re-found by MAC over Bonjour and its
/// address updated (DHCP lease moved it); nothing else ever changes the record.
@MainActor
final class KEFRediscoveryTests: XCTestCase {
    static let identity = KEFIdentity(model: "LS50WII", firmware: "V1", macAddress: "aabbcc001122")
    static let oldAddress = "192.0.2.10"
    static let newAddress = "192.0.2.21"

    final class ScanStub: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0; private var hits: [KEFDiscoveredSpeaker] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        var found: [KEFDiscoveredSpeaker] { get { lock.lock(); defer { lock.unlock() }; return hits } set { lock.lock(); hits = newValue; lock.unlock() } }
        func scan() -> [KEFDiscoveredSpeaker] { lock.lock(); defer { lock.unlock() }; value += 1; return hits }
    }

    var store: DeviceStore!
    var live: FakeKEFSpeaker!
    var dead: FakeKEFSpeaker!
    var scans: ScanStub!
    var found: [KEFDiscoveredSpeaker] { get { scans.found } set { scans.found = newValue } }
    var id: String { Self.identity.deviceID }

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "KEFRediscoveryTests-\(UUID())")!
        store = DeviceStore(bridge: NullKEFBridge(), defaults: defaults)
        live = FakeKEFSpeaker(state: KEFState(power: .active, volume: 20, muted: false, input: .wifi))
        dead = FakeKEFSpeaker(state: KEFState())
        dead.readFailure = .unreachable
        scans = ScanStub()
        found = [KEFDiscoveredSpeaker(identity: Self.identity, address: Self.newAddress)]
        var config = KEFConfig.defaults
        config.readbackDelay = 0.01
        store.setKEFConfigForTest(config)
        store.setKEFPersistenceForTest(KEFConfigurationStore(defaults: defaults))
        // Only the new address answers.
        store.setKEFClientFactoryForTest { [live, dead] address in address == Self.newAddress ? live! : dead! }
        store.setKEFDiscoverForTest { [scans] in scans!.scan() }
        store.addKEFSpeaker(identity: Self.identity, address: Self.oldAddress, name: "Living Room KEF", room: "Living Room")
    }

    private var address: String? { store.kefRecord(for: store.kefSpeakerDevices[0])?.address }

    /// The user's case: the app started after the IP moved (never a success).
    func testUnreachableSpeakerIsRefoundAndComesBackOnline() async {
        let ok = await store.refreshKEF(id)
        XCTAssertFalse(ok)
        for _ in 0..<200 where !(store.kefSpeakerDevices.first?.online ?? false) { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(address, Self.newAddress)
        XCTAssertTrue(store.kefSpeakerDevices[0].online, "read at the new address after the move")
        XCTAssertEqual(store.kefSpeakerDevices[0].name, "Living Room KEF")
        XCTAssertEqual(store.kefRecord(for: store.kefSpeakerDevices[0])?.room, "Living Room")
        XCTAssertEqual(scans.count, 1)
    }

    func testDifferentSpeakerOrSameAddressChangesNothing() async {
        found = [KEFDiscoveredSpeaker(identity: KEFIdentity(model: "LS50WII", firmware: "V1", macAddress: "ffffffffffff"), address: Self.newAddress)]
        await store.startKEFRediscovery(id, failedAddress: Self.oldAddress, manual: true)?.value
        XCTAssertEqual(address, Self.oldAddress)
        found = [KEFDiscoveredSpeaker(identity: Self.identity, address: Self.oldAddress)]
        await store.startKEFRediscovery(id, failedAddress: Self.oldAddress, manual: true)?.value
        XCTAssertEqual(address, Self.oldAddress)
    }

    func testRecordEditedOrRemovedMidScanIsLeftAlone() async {
        let task = store.startKEFRediscovery(id, failedAddress: Self.oldAddress, manual: true)
        store.updateKEFSpeaker(id: id, address: "192.0.2.50")  // user re-added it meanwhile
        await task?.value
        XCTAssertEqual(address, "192.0.2.50")
        let again = store.startKEFRediscovery(id, failedAddress: "192.0.2.50", manual: true)
        store.removeKEFSpeaker(id: id)
        await again?.value
        XCTAssertTrue(store.kefSpeakerDevices.isEmpty, "a removed speaker is never resurrected")
    }

    func testCooldownLimitsScansAndManualBypassesIt() async {
        found = []
        await store.startKEFRediscovery(id, failedAddress: Self.oldAddress, manual: false)?.value
        XCTAssertNil(store.startKEFRediscovery(id, failedAddress: Self.oldAddress, manual: false), "within cooldown")
        await store.startKEFRediscovery(id, failedAddress: Self.oldAddress, manual: true)?.value
        XCTAssertEqual(scans.count, 2)
    }

    func testConcurrentFailuresShareOneScan() async {
        let first = store.startKEFRediscovery(id, failedAddress: Self.oldAddress, manual: false)
        let second = store.startKEFRediscovery(id, failedAddress: Self.oldAddress, manual: false)
        XCTAssertNotNil(second, "joins the running scan instead of being dropped")
        await first?.value; await second?.value
        XCTAssertEqual(scans.count, 1)
    }

    /// DHCP gave the old IP to another device that answers HTTP: still re-found.
    func testForeignResponderAtOldAddressStillTriggersScan() async {
        dead.readFailure = .rejected(404)
        _ = await store.refreshKEF(id)
        for _ in 0..<200 where address != Self.newAddress { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(address, Self.newAddress)
    }

    /// Automatic `manual` refreshes (snapshots) respect the cooldown; only the user's Refresh bypasses it.
    func testOnlyUserRefreshBypassesCooldown() async {
        found = []
        _ = await store.refreshKEF(id)
        for _ in 0..<200 where scans.count == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        _ = await store.refreshKEF(id, manual: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(scans.count, 1)
        _ = await store.refreshKEF(id, manual: true, userInitiated: true)
        for _ in 0..<200 where scans.count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(scans.count, 2)
    }
}

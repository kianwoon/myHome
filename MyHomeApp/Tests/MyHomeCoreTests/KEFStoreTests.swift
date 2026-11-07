import XCTest
@testable import MyHomeCore

/// Stateful fake speaker: writes change `state` unless `ignoreWrites`.
final class FakeKEFSpeaker: KEFClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: KEFState
    private var _calls: [String] = []
    var ignoreWrites = false
    var readFailure: KEFError?
    var writeFailure: KEFError?
    /// After a power write, fetchState keeps returning the previous power for this many reads.
    var lagPowerReadsBy = 0
    private var lagPower: KEFPower?

    init(state: KEFState) { _state = state }
    var state: KEFState { get { lock.lock(); defer { lock.unlock() }; return _state } set { lock.lock(); _state = newValue; lock.unlock() } }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func log(_ text: String) { lock.lock(); _calls.append(text); lock.unlock() }

    func fetchIdentity() async throws -> KEFIdentity { KEFIdentity(model: "LS50WII", firmware: "V1", macAddress: "aabbcc001122") }
    func fetchState() async throws -> KEFState {
        log("read")
        if let readFailure { throw readFailure }
        var reading = state
        if lagPowerReadsBy > 0, let lagPower { reading.power = lagPower; lock.lock(); lagPowerReadsBy -= 1; lock.unlock() }
        return reading
    }
    private func write(_ name: String, _ apply: () -> Void) throws {
        log(name)
        if let writeFailure { throw writeFailure }
        if !ignoreWrites { apply() }
    }
    func setPower(_ on: Bool) async throws {
        let before = state.power
        try write("power:\(on)") { state.power = on ? .active : .standby }
        lock.lock(); lagPower = before; lock.unlock()
    }
    func setVolume(_ percent: Int) async throws { try write("volume:\(percent)") { state.volume = percent } }
    func setMuted(_ muted: Bool) async throws { try write("mute:\(muted)") { state.muted = muted } }
    func setInput(_ input: KEFInput) async throws { try write("input:\(input.wireValue)") { state.input = input } }
}

@MainActor
final class KEFStoreTests: XCTestCase {
    static let identity = KEFIdentity(model: "LS50WII", firmware: "V1", macAddress: "aabbcc001122")
    var store: DeviceStore!
    var speaker: FakeKEFSpeaker!
    var defaults: UserDefaults!
    var device: Device { store.kefSpeakerDevices[0] }

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "KEFStoreTests-\(UUID())")!
        store = DeviceStore(bridge: NullKEFBridge(), defaults: defaults)
        speaker = FakeKEFSpeaker(state: KEFState(power: .active, volume: 20, muted: false, input: .wifi, maxVolume: 60))
        var config = KEFConfig.defaults
        config.readbackDelay = 0.01
        store.setKEFConfigForTest(config)
        store.setKEFPersistenceForTest(KEFConfigurationStore(defaults: defaults))
        store.setKEFClientFactoryForTest { [speaker] _ in speaker! }
        store.addKEFSpeaker(identity: Self.identity, address: "192.0.2.10", name: "Living Room KEF", room: "Living Room")
        await store.refreshKEF(device.id)
    }

    func testRefreshPublishesConfirmedState() {
        XCTAssertEqual(store.kefState(for: device), speaker.state)
        XCTAssertEqual(store.kefPower(for: device), true)
        XCTAssertTrue(device.online)
        XCTAssertEqual(device.ip, "", "KEF must never look like a Tuya/Briturn addressed device")
    }

    func testDedupeKeepsNameRoomOnIPChangeAndPersists() {
        store.addKEFSpeaker(identity: Self.identity, address: "192.0.2.99", name: "", room: "")
        XCTAssertEqual(store.kefSpeakerDevices.count, 1)
        let record = store.kefRecord(for: device)!
        XCTAssertEqual(record.address, "192.0.2.99")
        XCTAssertEqual(record.name, "Living Room KEF")
        XCTAssertEqual(record.room, "Living Room")
        let reloaded = DeviceStore(bridge: NullKEFBridge(), defaults: defaults)
        XCTAssertEqual(reloaded.kefSpeakerDevices.map(\.id), ["kef:aabbcc001122"])
    }

    func testRosterAndCloudRefreshKeepKEF() {
        store.setRosterForTest([])
        XCTAssertTrue(store.devices.contains { $0.id == "kef:aabbcc001122" })
        store.briturnCloudDevices = ["x": try! BriturnCloudDevice(json: ["deviceId": 1, "entityType": "TCP_WF", "productId": 95, "macAddress": "aabbccddeeff"], homeID: 1)]
        XCTAssertTrue(store.devices.contains { $0.id == "kef:aabbcc001122" }, "cloud branch must keep KEF")
        XCTAssertEqual(store.devices.first { $0.id.hasPrefix("kef:") }?.kind, .speaker)
    }

    func testRemoveDeletesOnlyLocalRecord() {
        store.removeKEFSpeaker(id: device.id)
        XCTAssertTrue(store.kefSpeakerDevices.isEmpty)
        XCTAssertTrue(speaker.calls.filter { $0 != "read" }.isEmpty, "removal never writes to the speaker")
        XCTAssertTrue(KEFConfigurationStore(defaults: defaults).load().isEmpty)
    }

    func testFailureKeepsLastStateAsStaleAndBacksOff() async {
        let id = device.id
        speaker.readFailure = .unreachable
        let reads = speaker.calls.count
        let ok = await store.refreshKEF(id, manual: true)
        XCTAssertFalse(ok)
        XCTAssertEqual(store.kefReading(for: device)?.failures, 1)
        XCTAssertEqual(store.kefReading(for: device)?.lastError, .unreachable)
        XCTAssertNotNil(store.kefState(for: device), "last known value survives")
        XCTAssertFalse(store.devices.first { $0.id == id }!.online)
        XCTAssertEqual(speaker.calls.count - reads, 2, "read-only failure retries once")
        let before = speaker.calls.count
        _ = await store.refreshKEF(id)
        XCTAssertEqual(speaker.calls.count, before, "back-off skips the non-manual refresh")
        _ = await store.refreshKEF(id, manual: true)
        XCTAssertGreaterThan(speaker.calls.count, before, "manual refresh bypasses back-off")
    }

    func testVolumeWriteConfirmedByReadbackOnly() async {
        let outcome = await store.kefWrite(device, .volume(30))
        XCTAssertEqual(outcome, .confirmed(speaker.state))
        XCTAssertEqual(store.kefState(for: device)?.volume, 30)
    }

    func testIgnoredWriteIsMismatchAndNeverPublishedAsConfirmed() async {
        speaker.ignoreWrites = true
        let outcome = await store.kefWrite(device, .volume(30))
        guard case .mismatch(let state) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(state.volume, 20)
        XCTAssertEqual(store.kefState(for: device)?.volume, 20)
    }

    func testStandbyRefusesVolumeMuteInputWithoutWaking() async {
        speaker.state.power = .standby
        await store.refreshKEF(device.id, manual: true)
        for action in [KEFAction.volume(10), .mute(true), .input(.tv)] {
            let outcome = await store.kefWrite(device, action)
            XCTAssertEqual(outcome, .failed(.standbyBlocksWrite))
        }
        XCTAssertFalse(speaker.calls.contains { $0.hasPrefix("input") || $0.hasPrefix("volume") || $0.hasPrefix("mute") })
        XCTAssertEqual(speaker.state.power, .standby)
        if case .confirmed = await store.kefWrite(device, .power(true)) {} else { XCTFail("power on is allowed from standby") }
    }

    func testSlowPowerTransitionIsPolledUntilConfirmed() async {
        var config = KEFConfig.defaults
        config.readbackDelay = 0.01; config.powerSettleInterval = 0.05; config.powerSettleTimeout = 2
        store.setKEFConfigForTest(config)
        speaker.state.power = .standby
        await store.refreshKEF(device.id, manual: true)
        speaker.lagPowerReadsBy = 3   // speaker reports the old power state for 3 reads
        let outcome = await store.kefWrite(device, .power(true))
        if case .confirmed = outcome {} else { XCTFail("\(outcome)") }
        XCTAssertEqual(store.kefPower(for: device), true)
    }

    func testVolumeLimitIsEnforcedNotScaled() async {
        XCTAssertEqual(store.kefVolumeCeiling(for: device), 60)
        let outcome = await store.kefWrite(device, .volume(61))
        XCTAssertEqual(outcome, .failed(.volumeOutOfRange(0...60)))
        XCTAssertFalse(speaker.calls.contains { $0.hasPrefix("volume") })
    }

    func testMuteIndependentOfVolume() async {
        _ = await store.kefWrite(device, .mute(true))
        XCTAssertEqual(speaker.state.volume, 20)
        _ = await store.kefWrite(device, .mute(false))
        XCTAssertEqual(speaker.state.volume, 20, "unmute never resets the level")
        XCTAssertEqual(speaker.state.muted, false)
    }

    func testRapidVolumeIntentsLastWins() async {
        // Tasks enqueue on the main actor in creation order, so 45 is the last intent.
        let device = self.device
        let tasks = [25, 35, 45].map { value in Task { @MainActor in await self.store.kefWrite(device, .volume(value)) } }
        var outcomes: [KEFWriteOutcome] = []
        for task in tasks { outcomes.append(await task.value) }
        XCTAssertEqual(outcomes[0], .superseded, "an overtaken write must not report a false mismatch")
        XCTAssertEqual(outcomes[1], .superseded)
        if case .confirmed = outcomes[2] {} else { XCTFail("\(outcomes[2])") }
        XCTAssertEqual(speaker.state.volume, 45)
        let sent = speaker.calls.filter { $0.hasPrefix("volume") }
        XCTAssertEqual(sent.last, "volume:45")
        XCTAssertLessThan(sent.count, 3 + 1)
    }

    func testRejectedWriteSurfacesErrorAndKeepsConfirmedState() async {
        speaker.writeFailure = .rejected(500)
        let outcome = await store.kefWrite(device, .volume(30))
        XCTAssertEqual(outcome, .failed(.rejected(500)))
        XCTAssertEqual(store.kefState(for: device)?.volume, 20)
        XCTAssertFalse(KEFError.rejected(500).message.lowercased().contains("192.0.2"))
    }

    func testStaleReadDoesNotOverwriteNewerWrite() async {
        let id = device.id
        speaker.state.volume = 20
        // Simulate: a refresh began (generation g), a write landed (g+1), then the old read applies.
        let generation = store.kefReading(for: device)!.generation
        _ = await store.kefWrite(device, .volume(40))
        store.applyKEFReadForTest(id, state: KEFState(power: .active, volume: 20, muted: false, input: .wifi), generation: generation)
        XCTAssertEqual(store.kefState(for: device)?.volume, 40)
    }
}

/// A bridge that is never reached by KEF paths.
final class NullKEFBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        lock.lock(); count += 1; lock.unlock()
        return ["ok": true]
    }
}

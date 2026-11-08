import XCTest
@testable import MyHomeCore

/// Stateful fake Cast speaker: writes change `state` unless `ignoreWrites`.
final class FakeCastSpeaker: CastClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: CastState
    private var _calls: [String] = []
    var ignoreWrites = false
    var readFailure: CastError?

    init(state: CastState) { _state = state }
    var state: CastState { get { lock.lock(); defer { lock.unlock() }; return _state } set { lock.lock(); _state = newValue; lock.unlock() } }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func log(_ text: String) { lock.lock(); _calls.append(text); lock.unlock() }

    func fetchState() async throws -> CastState {
        log("read")
        if let readFailure { throw readFailure }
        return state
    }
    func setVolume(_ percent: Int) async throws { log("volume:\(percent)"); if !ignoreWrites { state.volume = percent } }
    func setMuted(_ muted: Bool) async throws { log("mute:\(muted)"); if !ignoreWrites { state.muted = muted } }
    func play(_ source: CastMediaSource) async throws {
        log("play:\(source.title)")
        guard source.isPlayable else { throw CastError.unplayableSource }
        if !ignoreWrites { state.appName = "Default Media Receiver"; state.playback = .playing }
    }
    func transport(_ action: CastAction) async throws {
        log("transport:\(action)")
        guard state.appName != nil else { throw CastError.noActiveSession }
        if ignoreWrites { return }
        switch action {
        case .play: state.playback = .playing
        case .pause: state.playback = .paused
        case .stop: state.appName = nil; state.playback = nil
        default: break
        }
    }
}

@MainActor
final class CastStoreTests: XCTestCase {
    var store: DeviceStore!
    var speaker: FakeCastSpeaker!
    var defaults: UserDefaults!
    var device: Device { store.castSpeakerDevices[0] }

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "CastStoreTests-\(UUID())")!
        store = DeviceStore(bridge: NullKEFBridge(), defaults: defaults)
        speaker = FakeCastSpeaker(state: CastState(volume: 40, muted: false, appName: "Spotify", playback: .playing))
        var config = CastConfig.defaults
        config.readbackDelay = 0.01
        store.setCastConfigForTest(config)
        store.setCastPersistenceForTest(CastConfigurationStore(defaults: defaults))
        store.setCastClientFactoryForTest { [speaker] _ in speaker! }
        store.addCastSpeaker(CastSpeakerRecord(deviceID: "abc123", name: "Living Room speaker", room: "Living Room",
                                               model: "Google Nest Mini", serviceName: "Google-Nest-Mini-abc123"))
        await store.refreshCast(device.id)
    }

    func testRefreshPublishesStateAndLooksLikeASpeaker() {
        XCTAssertEqual(store.castState(for: device), speaker.state)
        XCTAssertTrue(device.online)
        XCTAssertEqual(device.ip, "", "Cast must never look like a Tuya/Briturn addressed device")
        XCTAssertEqual(device.kind, .speaker)
        XCTAssertTrue(store.isCast(device))
        XCTAssertFalse(store.isKEF(device))
    }

    func testVolumeWriteIsConfirmedByReadback() async {
        let outcome = await store.castWrite(device, .volume(55))
        guard case .confirmed(let state) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(state.volume, 55)
        XCTAssertEqual(store.castState(for: device)?.volume, 55)
    }

    func testIgnoredWriteIsAMismatchNotASuccess() async {
        speaker.ignoreWrites = true
        guard case .mismatch = await store.castWrite(device, .mute(true)) else { return XCTFail("expected mismatch") }
        XCTAssertEqual(store.castState(for: device)?.muted, false, "the requested value must never be published before it is read")
    }

    func testOutOfRangeVolumeIsRejectedBeforeAnyIO() async {
        let before = speaker.calls.count
        guard case .failed(.volumeOutOfRange) = await store.castWrite(device, .volume(101)) else { return XCTFail() }
        XCTAssertEqual(speaker.calls.count, before)
    }

    func testTransportNeedsARunningSession() async {
        speaker.state.appName = nil
        await store.refreshCast(device.id, manual: true)
        guard case .failed(.noActiveSession) = await store.castWrite(device, .pause) else { return XCTFail() }
    }

    func testPauseAndStop() async {
        guard case .confirmed = await store.castWrite(device, .pause) else { return XCTFail("pause") }
        guard case .confirmed = await store.castWrite(device, .stop) else { return XCTFail("stop") }
        XCTAssertNil(store.castState(for: device)?.appName)
    }

    func testFailedReadMarksOfflineAndBacksOff() async {
        speaker.readFailure = .timeout
        await store.refreshCast(device.id, manual: true)
        XCTAssertFalse(device.online)
        XCTAssertEqual(store.reachability(for: device), .offline)
        XCTAssertNotNil(store.castReading(for: device)?.nextAttempt)
        speaker.readFailure = nil
        let skipped = await store.refreshCast(device.id)
        XCTAssertFalse(skipped, "back-off skips the non-manual refresh")
        let refreshed = await store.refreshCast(device.id, manual: true)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(device.online)
    }

    func testRecordsPersistAndRemove() {
        let reloaded = CastConfigurationStore(defaults: defaults).load()
        XCTAssertEqual(reloaded.map(\.deviceID), ["abc123"])
        store.removeCastSpeaker(id: device.id)
        XCTAssertTrue(CastConfigurationStore(defaults: defaults).load().isEmpty)
    }

    func testAddingSameDeviceUpdatesNotDuplicates() {
        store.addCastSpeaker(CastSpeakerRecord(deviceID: "abc123", name: "", room: "", model: "Google Nest Mini", serviceName: "renamed"))
        XCTAssertEqual(store.castSpeakerDevices.count, 1)
        XCTAssertEqual(store.castRecord(for: device)?.name, "Living Room speaker", "empty name keeps the existing one")
    }
}

@MainActor
final class CastControlTests: XCTestCase {
    func testCapabilitiesAreVolumeAndMuteOnly() {
        let device = Device(id: "cast:x", name: "Mini", ip: "", version: nil, category: CastProtocol.category, online: true)
        let profile = DeviceProfile(device: device, state: DeviceState(dps: [:]), isBriturn: false, isCast: true)
        XCTAssertEqual(CapabilityMap.supported(for: profile), [.volume, .mute, .media])
        guard case .success(.cast(.volume(30))) = CapabilityMap.plan(.volume(30), for: profile) else { return XCTFail() }
        guard case .failure = CapabilityMap.plan(.power(true), for: profile) else { return XCTFail("no power on a Cast speaker") }
        guard case .failure = CapabilityMap.plan(.volume(120), for: profile) else { return XCTFail() }
    }

    func testActionMatching() {
        let state = CastState(volume: 40, muted: true, appName: "App", playback: .paused)
        XCTAssertEqual(CastAction.volume(40).matches(state), true)
        XCTAssertEqual(CastAction.volume(60).matches(state), false)
        XCTAssertEqual(CastAction.mute(true).matches(state), true)
        XCTAssertEqual(CastAction.pause.matches(state), true)
        XCTAssertEqual(CastAction.play.matches(state), false)
        XCTAssertNil(CastAction.mute(true).matches(CastState()))
    }

    func testIPv4Validation() {
        XCTAssertTrue(CastSwiftClient.isValidIPv4("192.168.1.20"))
        XCTAssertFalse(CastSwiftClient.isValidIPv4("192.168.1"))
        XCTAssertFalse(CastSwiftClient.isValidIPv4("256.1.1.1"))
    }
}

final class CastDiscoveryTests: XCTestCase {
    struct StubBrowser: CastServiceBrowsing {
        let hits: [CastDiscoveredSpeaker]
        func browse(timeout: TimeInterval) async -> [CastDiscoveredSpeaker] { hits }
    }

    func testDedupesByIDAndSkipsTVsAndKEF() async {
        func hit(_ id: String, _ model: String, video: Bool = false) -> CastDiscoveredSpeaker {
            CastDiscoveredSpeaker(deviceID: id, name: id, model: model, serviceName: id, isGroup: false, supportsVideo: video)
        }
        let found = await CastSpeakerDiscovery.discover(browser: StubBrowser(hits: [
            hit("a", "Google Nest Mini"), hit("a", "Google Nest Mini"), hit("tv", "Chromecast", video: true), hit("kef", "LS50 Wireless II")
        ]), timeout: 1)
        XCTAssertEqual(found.map(\.deviceID), ["a"])
    }
}

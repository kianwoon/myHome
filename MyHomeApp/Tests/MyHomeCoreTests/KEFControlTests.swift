import XCTest
@testable import MyHomeCore

@MainActor
final class KEFControlTests: XCTestCase {
    private var store: DeviceStore!
    private var controller: DeviceController!
    private var speaker: FakeKEFSpeaker!
    private let lamp = ControlFixtures.device("light-1", name: "Desk Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let parser = VoiceCommandParser()
    private var kefDevice: Device { store.kefSpeakerDevices[0] }

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "KEFControlTests-\(UUID())")!
        store = DeviceStore(bridge: NullKEFBridge(), defaults: defaults)
        store.setRosterForTest([lamp])
        store.applyStatus(lamp.id, decoded: ["1": .bool(true), "2": .number(500)])
        speaker = FakeKEFSpeaker(state: KEFState(power: .active, volume: 20, muted: false, input: .wifi, maxVolume: 60))
        var config = KEFConfig.defaults
        config.readbackDelay = 0.01
        store.setKEFConfigForTest(config)
        store.setKEFClientFactoryForTest { [speaker] _ in speaker! }
        store.addKEFSpeaker(identity: KEFStoreTests.identity, address: "192.0.2.10", name: "Living Room KEF", room: "Living Room")
        await store.refreshKEF(kefDevice.id)
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 1, confirmationDeviceThreshold: 10, settleInterval: 0.1))
    }

    // MARK: grammar

    private func command(_ text: String) -> (DeviceQuery, DeviceCommand)? {
        if case .command(let query, let command) = parser.parse(text) { return (query, command) }
        return nil
    }

    func testSpeakerGrammar() {
        XCTAssertEqual(command("set kef volume to 30 percent")?.1, .volume(30))
        XCTAssertEqual(command("set kef volume to 30 percent")?.0.text, "kef")
        XCTAssertEqual(command("set the speakers volume to thirty")?.1, .volume(30))
        XCTAssertEqual(command("mute the speakers")?.1, .mute(true))
        XCTAssertEqual(command("unmute kef")?.1, .mute(false))
        XCTAssertEqual(command("unmute kef")?.0.text, "kef")
        XCTAssertEqual(command("switch kef to tv")?.1, .input("tv"))
        XCTAssertEqual(command("switch kef to optical")?.1, .input("optic"))
        XCTAssertEqual(command("turn on the living room speakers")?.1, .power(true))
        if case .status(let query) = parser.parse("what volume are the speakers at") { XCTAssertEqual(query.text, "speakers") } else { XCTFail("status") }
    }

    func testBrightnessStillTargetsLights() {
        XCTAssertEqual(command("set the desk lamp brightness to 40")?.1, .level(40))
        XCTAssertEqual(command("dim the desk lamp to 30")?.1, .level(30))
    }

    // MARK: capabilities and resolution

    func testCapabilityAdvertisingIsExplicit() {
        let speakerProfile = controller.profile(for: kefDevice)
        XCTAssertEqual(CapabilityMap.supported(for: speakerProfile), [.power, .volume, .mute, .input])
        XCTAssertFalse(CapabilityMap.supports(.level(50), profile: speakerProfile))
        let lampProfile = controller.profile(for: lamp)
        XCTAssertFalse(CapabilityMap.supports(.volume(30), profile: lampProfile))
        XCTAssertFalse(CapabilityMap.supports(.mute(true), profile: lampProfile))
    }

    func testVolumeNeverSelectsALight() async {
        let result = await controller.perform(.volume(30), on: DeviceQuery(text: "desk lamp"), origin: .text)
        XCTAssertEqual(result.outcomes.first?.device.id, lamp.id)
        XCTAssertNotEqual(result.outcomes.first?.status, .confirmed)
        XCTAssertTrue(speaker.calls.filter { $0 != "read" }.isEmpty)
    }

    func testPlanBoundsAndInputValidation() {
        let profile = controller.profile(for: kefDevice)
        XCTAssertEqual(CapabilityMap.plan(.volume(60), for: profile), .success(.kef(.volume(60))))
        XCTAssertEqual(CapabilityMap.plan(.volume(61), for: profile), .failure(.outOfRange(.volume, lower: 0, upper: 60)))
        XCTAssertEqual(CapabilityMap.plan(.input("wifi"), for: profile), .success(.kef(.input(.wifi))))
        guard case .failure(.unknownMode) = CapabilityMap.plan(.input("laserdisc"), for: profile) else { return XCTFail() }
    }

    // MARK: execution

    func testVolumeConfirmedFromReadback() async {
        let result = await controller.perform(.volume(35), on: DeviceQuery(text: "kef"), origin: .text)
        XCTAssertEqual(result.outcomes.first?.status, .confirmed)
        XCTAssertEqual(speaker.state.volume, 35)
    }

    func testMuteInputAndPower() async {
        var result = await controller.perform(.mute(true), on: DeviceQuery(text: "kef"), origin: .text)
        XCTAssertEqual(result.outcomes.first?.status, .confirmed)
        result = await controller.perform(.input("tv"), on: DeviceQuery(text: "kef"), origin: .text)
        XCTAssertEqual(result.outcomes.first?.status, .confirmed)
        XCTAssertEqual(speaker.state.input, .tv)
        result = await controller.perform(.power(false), on: DeviceQuery(text: "kef"), origin: .text)
        XCTAssertEqual(result.outcomes.first?.status, .confirmed)
        XCTAssertEqual(speaker.state.power, .standby)
    }

    func testStandbyDeniesVolumeButAllowsPower() async {
        speaker.state.power = .standby
        await store.refreshKEF(kefDevice.id, manual: true)
        let denied = await controller.perform(.volume(35), on: DeviceQuery(text: "kef"), origin: .text)
        XCTAssertNotEqual(denied.outcomes.first?.status, .confirmed)
        XCTAssertFalse(speaker.calls.contains { $0.hasPrefix("volume") })
        let on = await controller.perform(.power(true), on: DeviceQuery(text: "kef"), origin: .text)
        XCTAssertEqual(on.outcomes.first?.status, .confirmed)
    }

    func testIgnoredWriteIsNotConfirmed() async {
        speaker.ignoreWrites = true
        let result = await controller.perform(.volume(35), on: DeviceQuery(text: "kef"), origin: .text)
        guard case .rejected? = result.outcomes.first?.status else { return XCTFail("\(String(describing: result.outcomes.first?.status))") }
    }

    func testOfflineRefusesWrites() async {
        speaker.readFailure = .unreachable
        await store.refreshKEF(kefDevice.id, manual: true)
        let result = await controller.perform(.volume(35), on: DeviceQuery(text: "kef"), origin: .text)
        XCTAssertNotEqual(result.outcomes.first?.status, .confirmed)
        XCTAssertFalse(speaker.calls.contains { $0.hasPrefix("volume") })
    }

    // MARK: queries

    func testStatusAnswerUsesConfirmedStateAndLabelsStale() {
        let summary = controller.summary(for: kefDevice)
        XCTAssertEqual(CommandPhrasing.describe(summary), "Living Room KEF is on, volume 20%, not muted, input Wi-Fi")
        let stale = DeviceSummary(id: summary.id, name: summary.name, room: summary.room, group: nil, kind: .speaker, capabilities: summary.capabilities,
                                  reachability: .wifi, isControllable: true, isOn: true, levelPercent: nil,
                                  speaker: .init(volume: 20, muted: false, inputLabel: "Wi-Fi", isStale: true, secondsSinceUpdate: 300))
        XCTAssertTrue(CommandPhrasing.describe(stale).contains("last known"))
    }
}

import XCTest
@testable import MyHomeCore

private final class FakeOutput: AudioOutputControlling {
    var defaultUID: String? = "speakers"
    var devices: [String: AudioOutputSnapshot]
    var failSet = false
    private(set) var writes: [String] = []

    init(_ devices: [AudioOutputSnapshot]) {
        self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceUID, $0) })
    }

    func defaultOutputDeviceUID() -> String? { defaultUID }
    func snapshot(deviceUID: String) -> AudioOutputSnapshot? { devices[deviceUID] }

    func setMuted(_ muted: Bool, deviceUID: String) -> Bool {
        guard !failSet, devices[deviceUID]?.muted != nil else { return false }
        devices[deviceUID]?.muted = muted
        writes.append("mute:\(deviceUID):\(muted)")
        return true
    }

    func setVolumes(_ volumes: [Float], deviceUID: String) -> Bool {
        guard !failSet, let count = devices[deviceUID]?.volumes.count, count == volumes.count else { return false }
        devices[deviceUID]?.volumes = volumes
        writes.append("vol:\(deviceUID)")
        return true
    }
}

@MainActor
final class AudioOutputGateTests: XCTestCase {
    private var suite = ""

    private func defaults(mode: AppSettings.ListenOutputMode = .mute, duck: Double? = nil) -> UserDefaults {
        suite = "AudioOutputGateTests-\(UUID())"
        let d = UserDefaults(suiteName: suite)!
        d.set(mode.rawValue, forKey: AppSettings.listenOutputModeKey)
        if let duck { d.set(duck, forKey: AppSettings.listenDuckLevelKey) }
        return d
    }

    private func speakers(muted: Bool? = false, volumes: [Float] = [0.6]) -> AudioOutputSnapshot {
        AudioOutputSnapshot(deviceUID: "speakers", muted: muted, volumes: volumes)
    }

    func testDefaultModeIsMute() {
        XCTAssertEqual(AppSettings.listenOutputMode(from: UserDefaults(suiteName: "x-\(UUID())")!), .mute)
    }

    func testMuteThenRestore() {
        let out = FakeOutput([speakers()])
        let gate = ListeningOutputGate(controller: out, defaults: defaults())
        gate.begin()
        XCTAssertEqual(out.devices["speakers"]?.muted, true)
        XCTAssertEqual(out.devices["speakers"]?.volumes, [0.6], "mute must not touch the volume")
        XCTAssertEqual(gate.lastEngagement, .muted)
        gate.end()
        XCTAssertEqual(out.devices["speakers"], speakers())
        XCTAssertFalse(gate.isEngaged)
    }

    func testAlreadyMutedStaysMuted() {
        let out = FakeOutput([speakers(muted: true)])
        let gate = ListeningOutputGate(controller: out, defaults: defaults())
        gate.begin()
        XCTAssertEqual(gate.lastEngagement, .alreadySilent)
        gate.end()
        XCTAssertEqual(out.devices["speakers"]?.muted, true)
        XCTAssertTrue(out.writes.isEmpty)
    }

    func testModeOffDoesNothing() {
        let out = FakeOutput([speakers()])
        let gate = ListeningOutputGate(controller: out, defaults: defaults(mode: .off))
        gate.begin()
        gate.end()
        XCTAssertTrue(out.writes.isEmpty)
        XCTAssertEqual(gate.lastEngagement, .off)
    }

    func testDuckScalesCurrentVolumeAndRestores() {
        let out = FakeOutput([speakers(volumes: [0.8, 0.4])])
        let gate = ListeningOutputGate(controller: out, defaults: defaults(mode: .duck, duck: 0.25))
        gate.begin()
        XCTAssertEqual(out.devices["speakers"]?.volumes, [0.2, 0.1])
        XCTAssertEqual(out.devices["speakers"]?.muted, false)
        XCTAssertEqual(gate.lastEngagement, .ducked)
        gate.end()
        XCTAssertEqual(out.devices["speakers"]?.volumes, [0.8, 0.4])
    }

    func testDuckLevelIsClampedToRange() {
        let d = defaults(mode: .duck, duck: 5)
        XCTAssertEqual(AppSettings.listenDuckLevel(from: d), AppSettings.listenDuckLevelRange.upperBound)
    }

    func testVolumeFallbackWhenNoMuteProperty() {
        let out = FakeOutput([speakers(muted: nil, volumes: [0.5])])
        let gate = ListeningOutputGate(controller: out, defaults: defaults())
        gate.begin()
        XCTAssertEqual(out.devices["speakers"]?.volumes, [0])
        gate.end()
        XCTAssertEqual(out.devices["speakers"]?.volumes, [0.5])
    }

    func testCannotMuteReportedNotSilent() {
        let out = FakeOutput([speakers(muted: nil, volumes: [])])
        let gate = ListeningOutputGate(controller: out, defaults: defaults())
        gate.begin()
        XCTAssertEqual(gate.lastEngagement, .unsupported(ListeningOutputGate.cannotMuteMessage))
        XCTAssertEqual(gate.probe(), .none)
        gate.end()
        XCTAssertTrue(out.writes.isEmpty)
    }

    func testNoDeviceReported() {
        let out = FakeOutput([])
        out.defaultUID = nil
        let gate = ListeningOutputGate(controller: out, defaults: defaults())
        gate.begin()
        XCTAssertEqual(gate.lastEngagement, .unsupported(ListeningOutputGate.noDeviceMessage))
        XCTAssertEqual(gate.probe(), .noDevice)
    }

    func testWriteFailureRollsBackAndClearsRecord() {
        let out = FakeOutput([speakers()])
        out.failSet = true
        let d = defaults()
        let gate = ListeningOutputGate(controller: out, defaults: d)
        gate.begin()
        XCTAssertEqual(gate.lastEngagement, .unsupported(ListeningOutputGate.changeFailedMessage))
        XCTAssertNil(d.data(forKey: AppSettings.listenOutputPendingKey))
        XCTAssertFalse(gate.isEngaged)
    }

    func testRestoreOnCancelErrorAndTermination() {
        for finish in [{ (g: ListeningOutputGate) in g.end() },          // cancel / error path
                       { (g: ListeningOutputGate) in g.restoreNow() }] { // termination / sleep
            let out = FakeOutput([speakers()])
            let gate = ListeningOutputGate(controller: out, defaults: defaults())
            gate.begin()
            finish(gate)
            XCTAssertEqual(out.devices["speakers"], speakers())
        }
    }

    func testDoublePressAndOverlapUseOneMute() {
        let out = FakeOutput([speakers()])
        let gate = ListeningOutputGate(controller: out, defaults: defaults())
        gate.begin()
        gate.begin()
        XCTAssertEqual(out.writes.count, 1)
        gate.end()
        XCTAssertEqual(out.devices["speakers"]?.muted, true, "still held by the other session")
        gate.end()
        XCTAssertEqual(out.devices["speakers"]?.muted, false)
        gate.end()   // extra end is ignored
        XCTAssertEqual(gate.holderCount, 0)
        XCTAssertEqual(out.devices["speakers"]?.muted, false)
    }

    func testSettleRestoresBeforeReplyButNotWhileHeld() {
        let out = FakeOutput([speakers()])
        let gate = ListeningOutputGate(controller: out, defaults: defaults())
        gate.begin()
        gate.settle()
        XCTAssertEqual(out.devices["speakers"]?.muted, true, "settle must not unmute a live session")
        gate.end()
        gate.settle()
        XCTAssertEqual(out.devices["speakers"]?.muted, false)
    }

    func testDeviceChangeMidHoldRestoresOriginalOnly() {
        let headphones = AudioOutputSnapshot(deviceUID: "headphones", muted: false, volumes: [0.3])
        let out = FakeOutput([speakers(), headphones])
        let gate = ListeningOutputGate(controller: out, defaults: defaults())
        gate.begin()
        out.defaultUID = "headphones"
        gate.end()
        XCTAssertEqual(out.devices["speakers"]?.muted, false)
        XCTAssertEqual(out.devices["headphones"], headphones, "the new default is never touched")
        XCTAssertFalse(out.writes.contains { $0.contains("headphones") })
    }

    func testUserChangeDuringHoldIsNotOverwritten() {
        let out = FakeOutput([speakers()])
        let gate = ListeningOutputGate(controller: out, defaults: defaults())
        gate.begin()
        out.devices["speakers"]?.muted = false   // user hit the volume key
        out.devices["speakers"]?.volumes = [0.9]
        gate.end()
        XCTAssertEqual(out.devices["speakers"]?.volumes, [0.9])
        XCTAssertEqual(out.devices["speakers"]?.muted, false)
    }

    func testCrashRecoveryRestoresWhenStillInOurState() {
        let out = FakeOutput([speakers()])
        let d = defaults()
        let first = ListeningOutputGate(controller: out, defaults: d)
        first.begin()                                  // ...app crashes here
        XCTAssertNotNil(d.data(forKey: AppSettings.listenOutputPendingKey))
        let relaunched = ListeningOutputGate(controller: out, defaults: d)
        relaunched.recoverPending()
        XCTAssertEqual(out.devices["speakers"]?.muted, false)
        XCTAssertNil(d.data(forKey: AppSettings.listenOutputPendingKey))
    }

    func testCrashRecoveryLeavesUserChangedStateAndMissingDevice() {
        let out = FakeOutput([speakers()])
        let d = defaults()
        let first = ListeningOutputGate(controller: out, defaults: d)
        first.begin()
        out.devices["speakers"]?.muted = false   // user already fixed it
        out.devices["speakers"]?.volumes = [0.2]
        ListeningOutputGate(controller: out, defaults: d).recoverPending()
        XCTAssertEqual(out.devices["speakers"]?.volumes, [0.2])

        let gone = FakeOutput([speakers()])
        let d2 = defaults()
        ListeningOutputGate(controller: gone, defaults: d2).begin()
        gone.devices = [:]
        ListeningOutputGate(controller: gone, defaults: d2).recoverPending()
        XCTAssertNil(d2.data(forKey: AppSettings.listenOutputPendingKey))
    }

    func testRecordClearedAfterNormalRestore() {
        let out = FakeOutput([speakers()])
        let d = defaults()
        let gate = ListeningOutputGate(controller: out, defaults: d)
        gate.begin()
        gate.end()
        XCTAssertNil(d.data(forKey: AppSettings.listenOutputPendingKey))
    }
}

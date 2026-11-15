import Foundation
import XCTest
@testable import MyHomeCore

/// Async bridge: per-device delay and reply for `set`/`status`, records every
/// request with a timestamp and tracks how many requests are in flight per id.
private final class TimedBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [(cmd: String, id: String, at: Date)] = []
    private var _setKeys: [(id: String, keys: [String])] = []
    private var inFlight: [String: Int] = [:]
    private var _maxPerID: [String: Int] = [:]
    private var total = 0
    private var _maxTotal = 0
    var setDelay: [String: TimeInterval] = [:]
    var onSet: (String, Int) throws -> [String: Any] = { _, _ in ["ok": true] }
    var onStatus: (String) -> [String: Any] = { _ in ["ok": false, "error": "no status"] }

    var log: [(cmd: String, id: String, at: Date)] { lock.lock(); defer { lock.unlock() }; return _log }
    var maxPerID: [String: Int] { lock.lock(); defer { lock.unlock() }; return _maxPerID }
    var maxTotal: Int { lock.lock(); defer { lock.unlock() }; return _maxTotal }
    func sets(_ id: String) -> [Date] { log.filter { $0.cmd == "set" && $0.id == id }.map(\.at) }
    /// The dp keys of each `set` to `id`, in the order they arrived.
    func setKeys(_ id: String) -> [[String]] { lock.lock(); defer { lock.unlock() }; return _setKeys.filter { $0.id == id }.map(\.keys) }

    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let cmd = payload["cmd"] as? String ?? ""
        let id = payload["id"] as? String ?? ""
        lock.lock()
        _log.append((cmd, id, Date()))
        if cmd == "set" { _setKeys.append((id, ((payload["dps"] as? [String: Any]) ?? [:]).keys.sorted())) }
        let setNumber = _log.filter { $0.cmd == "set" && $0.id == id }.count
        inFlight[id, default: 0] += 1
        _maxPerID[id] = max(_maxPerID[id] ?? 0, inFlight[id]!)
        total += 1
        _maxTotal = max(_maxTotal, total)
        let delay = cmd == "set" ? (setDelay[id] ?? 0) : 0
        lock.unlock()
        defer { lock.lock(); inFlight[id, default: 1] -= 1; total -= 1; lock.unlock() }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if cmd == "set" { return try onSet(id, setNumber) }
        if cmd == "status" { return onStatus(id) }
        return ["ok": true]
    }
}

private struct Boom: Error {}

@MainActor
final class WriteRetryConcurrencyTests: XCTestCase {
    private var bridge: TimedBridge!
    private var store: DeviceStore!
    private var controller: DeviceController!

    private let fan = ControlFixtures.device("fan-study", name: "Study Fan", category: "fs", room: "Study", spec: ControlFixtures.fanSpec)
    private let lamp = ControlFixtures.device("light-1", name: "Desk Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let curtain = ControlFixtures.device("curtain-study", name: "Study Curtain", category: "cl", room: "Study", spec: ControlFixtures.curtainSpec)

    override func setUp() {
        super.setUp()
        bridge = TimedBridge()
        store = DeviceStore(bridge: bridge, defaults: UserDefaults(suiteName: "WriteRetryConcurrencyTests-\(UUID())")!)
        store.setRosterForTest([fan, lamp, curtain])
        store.applyStatus(fan.id, decoded: ["1": .bool(false), "2": .string("custom"), "3": .number(2)])
        store.applyStatus(lamp.id, decoded: ["1": .bool(false), "2": .number(300)])
        store.applyStatus(curtain.id, decoded: ["1": .string("stop"), "2": .number(0)])
        controller = makeController()
    }

    private func makeController(retries: Int = 1, backoff: TimeInterval = 0.01, minRemaining: TimeInterval = 0, parallel: Int = 3,
                                perDevice: TimeInterval = 5, global: TimeInterval = 10, verify: TimeInterval = 0.2) -> DeviceController {
        DeviceController(store: store, config: ControlConfig(
            verifyTimeout: verify, confirmationDeviceThreshold: 10, settleInterval: 0.05,
            retry: WriteRetryPolicy(maxRetries: retries, backoff: backoff, minRemaining: minRemaining),
            parallelDevices: parallel, perDeviceBudget: perDevice, globalBudget: global))
    }

    private func run(_ command: DeviceCommand, on devices: [Device]) async -> CommandResult {
        let resolution: Resolution = devices.count == 1 ? .single(devices[0]) : .set(devices, scope: .all)
        return await controller.perform(CommandRequest(resolution: resolution, command: command, origin: .text, confirmed: true))
    }

    // MARK: Retry

    func testUnknownOutcomeIsRetriedAndTheSecondWriteConfirms() async {
        bridge.onSet = { _, number in
            if number == 1 { throw Boom() }
            return ["ok": true, "dps": ["1": false]]
        }
        bridge.onStatus = { _ in ["ok": true, "dps": ["1": true]] }   // still on after the lost write
        store.applyStatus(fan.id, decoded: ["1": .bool(true), "3": .number(2)])
        let result = await run(.power(false), on: [fan])
        XCTAssertEqual(bridge.sets(fan.id).count, 2, "one retry after the unknown outcome")
        XCTAssertEqual(result.outcomes.map(\.status), [.confirmed])
        XCTAssertEqual(result.outcomes.first?.attempts, 2)
    }

    func testRetryCountIsCappedAndReportedWithBackoff() async {
        controller = makeController(retries: 2, backoff: 0.15)
        bridge.onSet = { _, _ in throw Boom() }
        bridge.onStatus = { _ in ["ok": false, "error": "timed out"] }
        let result = await run(.cover(.open), on: [curtain])
        let sets = bridge.sets(curtain.id)
        XCTAssertEqual(sets.count, 3, "first write + maxRetries")
        XCTAssertGreaterThanOrEqual(sets[1].timeIntervalSince(sets[0]), 0.15, "backoff before retry 1")
        XCTAssertGreaterThanOrEqual(sets[2].timeIntervalSince(sets[1]), 0.30, "backoff grows with the retry number")
        guard case .uncertain = result.outcomes[0].status else { return XCTFail("\(result.outcomes[0].status)") }
        XCTAssertEqual(result.outcomes[0].attempts, 3)
        XCTAssertTrue(result.spokenSummary.contains("tried 3 times"), result.spokenSummary)
        XCTAssertTrue(result.spokenSummary.contains("it may not have changed"), result.spokenSummary)
    }

    func testSlowTimeoutAtDefaultProportionsIsRetriedOnce() async {
        // The shipped defaults scaled down 10x: 20s budget, 4s min-remaining,
        // 3s verify, 6s bridge timeout. A full timeout still leaves room for one retry.
        let scale = 0.1
        controller = makeController(backoff: AppSettings.defaultControlRetryBackoff * scale,
                                    minRemaining: AppSettings.defaultControlRetryMinRemaining * scale,
                                    perDevice: AppSettings.defaultControlPerDeviceBudget * scale,
                                    verify: AppSettings.defaultCommandVerifyTimeout * scale)
        bridge.setDelay = [fan.id: 6 * scale]
        bridge.onSet = { _, _ in throw Boom() }
        bridge.onStatus = { _ in ["ok": false, "error": "timed out"] }
        let result = await run(.power(true), on: [fan])
        XCTAssertEqual(bridge.sets(fan.id).count, 2, "the default budget leaves room for one retry after a full timeout")
        guard case .uncertain = result.outcomes[0].status else { return XCTFail("\(result.outcomes[0].status)") }
        XCTAssertTrue(result.spokenSummary.contains("tried 2 times"), result.spokenSummary)
    }

    func testDefiniteRejectionIsNeverRetried() async {
        bridge.onSet = { _, _ in ["ok": false, "error": "bad device id"] }
        let result = await run(.power(true), on: [fan])
        XCTAssertEqual(bridge.sets(fan.id).count, 1)
        XCTAssertEqual(result.outcomes.map(\.status), [.rejected("bad device id")])
        XCTAssertEqual(result.spokenSummary, "Couldn't turn on Study Fan: bad device id.")
    }

    func testRetryOffMeansOneWrite() async {
        controller = makeController(retries: 0)
        bridge.onSet = { _, _ in throw Boom() }
        let result = await run(.power(true), on: [fan])
        XCTAssertEqual(bridge.sets(fan.id).count, 1)
        guard case .uncertain = result.outcomes[0].status else { return XCTFail("\(result.outcomes[0].status)") }
    }

    func testReadBackShowingTheValueSkipsTheRetry() async {
        controller = makeController(backoff: 0.1)
        var firstSet: Date?
        bridge.onSet = { _, _ in firstSet = firstSet ?? Date(); throw Boom() }
        // Unreadable during the verify window (0.2s), then the device shows the value.
        bridge.onStatus = { _ in
            guard let firstSet, Date().timeIntervalSince(firstSet) > 0.25 else { return ["ok": false, "error": "timed out"] }
            return ["ok": true, "dps": ["1": true]]
        }
        let result = await run(.power(true), on: [fan])
        XCTAssertEqual(bridge.sets(fan.id).count, 1, "the device already shows it: nothing is re-sent")
        XCTAssertEqual(result.outcomes.map(\.status), [.confirmed])
    }

    func testOnlyIdempotentCommandsAreRetryable() {
        let policy = WriteRetryPolicy(maxRetries: 3, backoff: 0, minRemaining: 0)
        for command: DeviceCommand in [.power(true), .level(40), .fanSpeed(2), .cover(.close), .volume(20), .mute(true), .mode("nature")] {
            XCTAssertTrue(policy.allowsRetry(command, attempts: 1, remaining: 10), "\(command)")
        }
        for command: DeviceCommand in [.play("jazz"), .playback(.resume), .playback(.pause)] {
            XCTAssertFalse(policy.allowsRetry(command, attempts: 1, remaining: 10), "\(command) is never repeated")
        }
        XCTAssertFalse(policy.allowsRetry(.power(true), attempts: 4, remaining: 10), "capped")
        XCTAssertFalse(WriteRetryPolicy(maxRetries: 1, backoff: 0, minRemaining: 4).allowsRetry(.power(true), attempts: 1, remaining: 3),
                       "not enough budget left")
    }

    func testTransportFailureClassification() {
        XCTAssertTrue(WriteFailureClass.isAmbiguous(KEFError.timeout))
        XCTAssertFalse(WriteFailureClass.isAmbiguous(KEFError.rejected(400)))
        XCTAssertTrue(WriteFailureClass.isAmbiguous(CastError.unreachable))
        XCTAssertFalse(WriteFailureClass.isAmbiguous(CastError.noActiveSession))
        // Real texts: Briturn bridge TCP send failure (+ the store's BLE suffix),
        // the app-side bridge timeout, and tinytuya's error_text for 901/902/905.
        for text in ["power command failed (Bluetooth not in range for this light.)",
                     BridgeError.timeout.localizedDescription + " (Bluetooth not in range for this light.)",
                     "Network Error: Unable to Connect: 901", "Timeout Waiting for Device: 902",
                     "Network Error: Device Unreachable: 905", "device unreachable for brightness read"] {
            XCTAssertTrue(WriteFailureClass.isAmbiguous(message: text), text)
        }
        for text in [DeviceStore.noTransportMessage, "unknown briturn device id", "bad device id",
                     BLEReason.notSeen, "Briturn device has no IP yet — run a Briturn scan."] {
            XCTAssertFalse(WriteFailureClass.isAmbiguous(message: text), text)
        }
    }

    // MARK: No address

    func testNoAddressIsAnExplicitResultNotASilentFalse() async {
        let bare = ControlFixtures.device("plug-x", name: "Garage Plug", category: "cz", ip: "")
        let result = await store.setDpsReporting(bare, ["1": true])
        XCTAssertEqual(result, .noAddress(bluetoothOnly: false))
        XCTAssertEqual(result.message, SetDpsResult.noAddressText)
        XCTAssertTrue(bridge.log.isEmpty, "nothing was sent")
    }

    func testBluetoothOnlyTuyaDeviceIsRefusedWithAClearReason() async {
        let bleTuya = ControlFixtures.device("plug-ble", name: "Porch Plug", category: "cz", ip: "")
        store.setRosterForTest([fan, lamp, curtain, bleTuya])
        store.bleFallbackIDs.insert(bleTuya.id)
        let result = await run(.power(true), on: [bleTuya])
        XCTAssertEqual(result.outcomes.map(\.status), [.denied(SetDpsResult.bluetoothOnlyText)])
        XCTAssertTrue(bridge.log.isEmpty)
        XCTAssertTrue(result.spokenSummary.contains("no Bluetooth control path"), result.spokenSummary)
    }

    // MARK: Concurrency

    func testConcurrentWritesKeepTheirOwnMessages() async {
        bridge.setDelay = [fan.id: 0.2, lamp.id: 0.05]
        let fanID = fan.id
        bridge.onSet = { id, _ in ["ok": false, "error": id == fanID ? "fan says no" : "lamp says no"] }
        let result = await run(.power(true), on: [fan, lamp])
        XCTAssertEqual(result.outcomes.map(\.device.id), [fan.id, lamp.id], "outcomes stay in target order")
        XCTAssertEqual(result.outcomes.map(\.status), [.rejected("fan says no"), .rejected("lamp says no")])
        XCTAssertGreaterThanOrEqual(bridge.maxTotal, 2, "different devices are written at the same time")
    }

    func testParallelOneRunsDevicesOneAtATime() async {
        controller = makeController(parallel: 1)
        bridge.setDelay = [fan.id: 0.1, lamp.id: 0.1]
        bridge.onSet = { _, _ in ["ok": true] }
        _ = await run(.power(true), on: [fan, lamp])
        XCTAssertEqual(bridge.maxTotal, 1)
    }

    func testSlowDeviceDoesNotStarveTheOthers() async {
        controller = makeController(perDevice: 0.4, global: 5)
        bridge.setDelay = [fan.id: 3]
        bridge.onSet = { _, _ in ["ok": true, "dps": ["1": true]] }
        let started = Date()
        let result = await run(.power(true), on: [fan, lamp])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the hung device is cut off at its own budget")
        XCTAssertEqual(result.outcomes[1].status, .confirmed, "the lamp is not held up by the fan")
        guard case .uncertain(let text) = result.outcomes[0].status else { return XCTFail("\(result.outcomes[0].status)") }
        XCTAssertTrue(text.contains("no reply within"), text)
    }

    func testGlobalBudgetMarksUnstartedDevicesNotAttempted() async {
        controller = makeController(parallel: 1, perDevice: 0.3, global: 0.3)
        bridge.setDelay = [fan.id: 3]
        let result = await run(.power(true), on: [fan, lamp])
        XCTAssertEqual(result.outcomes[1].status, .denied(DeviceController.notAttemptedText))
        XCTAssertEqual(result.outcomes[1].attempts, 0)
        XCTAssertTrue(bridge.sets(lamp.id).isEmpty)
    }

    func testSameDeviceWritesAreSerializedAcrossCommands() async {
        bridge.setDelay = [fan.id: 0.15]
        bridge.onSet = { _, _ in ["ok": true] }
        let controller = self.controller!
        async let first = controller.perform(CommandRequest(resolution: .single(fan), command: .power(true), origin: .text, confirmed: true))
        async let second = controller.perform(CommandRequest(resolution: .single(fan), command: .fanSpeed(3), origin: .text, confirmed: true))
        _ = await (first, second)
        XCTAssertEqual(bridge.sets(fan.id).count, 2)
        XCTAssertEqual(bridge.maxPerID[fan.id], 1, "never two writes in flight to one device")
    }

    func testGateRunsQueuedWorkAndReleases() async {
        let gate = DeviceWriteGate()
        var order: [Int] = []
        async let a: Int? = gate.run("x") { try? await Task.sleep(nanoseconds: 50_000_000); order.append(1); return 1 }
        async let b: Int? = gate.run("x") { order.append(2); return 2 }
        _ = await (a, b)
        XCTAssertEqual(order.sorted(), [1, 2])
        XCTAssertTrue(gate.busyIDs.isEmpty, "the gate is released")
    }

    func testDeadlineFromACancelledTaskReturnsAtOnce() async {
        let task = Task { () -> Int? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await Deadline.run(seconds: 30) { 1 }
        }
        let started = Date()
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCompoundClausesRunPerDeviceLanesInSpokenOrder() async {
        bridge.setDelay = [fan.id: 0.15, lamp.id: 0.15]
        bridge.onSet = { _, _ in ["ok": true] }
        let assistant = AssistantCoordinator(controller: controller)
        let requests = [CommandRequest(resolution: .single(fan), command: .power(true), origin: .voice, confirmed: true),
                        CommandRequest(resolution: .single(lamp), command: .power(true), origin: .voice, confirmed: true),
                        CommandRequest(resolution: .single(fan), command: .fanSpeed(3), origin: .voice, confirmed: true)]
        let results = await assistant.runClauses(requests)
        XCTAssertEqual(results.map(\.command), requests.map(\.command), "results in clause order")
        XCTAssertEqual(bridge.setKeys(fan.id), [["1"], ["3"]], "same-device clauses run in spoken order")
        XCTAssertEqual(bridge.maxPerID[fan.id], 1)
        XCTAssertGreaterThanOrEqual(bridge.maxTotal, 2, "the lamp runs alongside the fan")
    }

    // MARK: Budget fit

    func testOuterDeadlineCoversTheControllerBudget() {
        let config = ControlConfig()
        let assistant = AssistantCoordinator(controller: controller)
        controller.config = config
        for count in 1...8 {
            XCTAssertGreaterThan(assistant.commandDeadline(forDevices: count), config.executionBudget(forDevices: count), "\(count) devices")
        }
        XCTAssertEqual(config.executionBudget(forDevices: 1), AppSettings.defaultControlPerDeviceBudget)
        XCTAssertEqual(config.executionBudget(forDevices: 50), AppSettings.defaultControlGlobalBudget)
    }
}

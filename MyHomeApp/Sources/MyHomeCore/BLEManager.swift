// baseline-guard:allow new BLE source, no prior baseline
// BLE transport for Zengge LEDnetWF lights (IOTWF* / LEDnetWF* advertisers).
//
// General rule: BLE lights are the SAME feature surface as the WiFi briturn
// lights (power/colour/brightness, same BriturnState cache, same cards) —
// only the transport differs. State comes from ADVERTISEMENTS (no connection
// needed to display); commands connect on demand, write to FF01 wrapped in
// the LEDnetWF transport layer, and disconnect again so the adapter's
// connection slots stay free.
//
// Protocol refs: 8none1/lednetwf_ble protocol_docs 01/02/04/05, and
// rabidpaperclip/magichome2-ble docs/protocol_map.md (same FFFF/FF01/FF02
// profile, same transport framing).

@preconcurrency import CoreBluetooth
import Foundation

public struct BLELight: Identifiable, Equatable, Codable {
    public let id: String            // "ble-<peripheral uuid>" (see BLEManager.lightID)
    public let name: String
    public let rssi: Int
}

@MainActor
public final class BLEManager: NSObject, ObservableObject {
    /// Under XCTest the CBCentralManager is never created: the test host has no
    /// Bluetooth usage description, so TCC aborts the process asynchronously.
    public static let shared = BLEManager(
        startCentral: NSClassFromString("XCTestCase") == nil)

    @Published public private(set) var lights: [BLELight] = []
    /// Latest advertisement-decoded state per BLE light id, shared with the
    /// store's briturnStatus cache so cards/pickers treat BLE and WiFi alike.
    @Published public private(set) var states: [String: DeviceStore.BriturnState] = [:]
    @Published public private(set) var isBluetoothOn = false
    @Published public private(set) var diagnostics = BLEDiagnostics()
    private static let summaryIntervalNanos: UInt64 = 30_000_000_000

    private var central: CBCentralManager!
    private var peripherals: [String: CBPeripheral] = [:]   // id -> peripheral
    /// Pre-filter advert accounting (every peripheral heard, accepted or not).
    private var advertUUIDsSeen: Set<UUID> = []
    private var advertUUIDsAccepted: Set<UUID> = []
    private var rawStates: [String: DeviceStore.BriturnState] = [:]
    // Identity is the PERIPHERAL UUID everywhere (ids, link state). Manufacturer
    // data is only ever used to decode state: the bytes once used as a "MAC"
    // were state plus a fixed product tail and collided across bulbs.
    /// Pending post-connect actions; the argument is nil on success or the
    /// failure reason (logged by the caller).
    private var connectRequests: [UUID: [(String?) -> Void]] = [:]
    private var writeChars: [UUID: CBCharacteristic] = [:]
    private var notifyReady: [UUID: Bool] = [:]
    private var seq: UInt8 = 0
    /// Devices commanded recently keep their connection briefly so a slider
    /// burst doesn't reconnect per step.
    private var disconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var connectTimeouts: [UUID: Task<Void, Never>] = [:]
    private static let disconnectDelay: UInt64 = 2_500_000_000
    /// A connect that has not reached notify-ready by then is abandoned and
    /// logged (e.g. the bulb's single link is held by the phone app).
    private static let connectTimeoutNanos: UInt64 = 10_000_000_000

    private init(startCentral: Bool) {
        super.init()
        if startCentral { central = CBCentralManager(delegate: self, queue: nil) }
        diagnostics.authorization = BLEAuthorization(CBCentralManager.authorization)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.summaryIntervalNanos)
                self?.logSummary()
            }
        }
    }

    private func logSummary() {
        let d = diagnostics
        let total = advertUUIDsSeen.count, acc = advertUUIDsAccepted.count
        let lastSeen = d.lastDiscovery.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        AppLog.ble.notice("MyHome: BLE auth=\(d.authorization.rawValue, privacy: .public) state=\(d.state.rawValue, privacy: .public) scanning=\(d.isScanning ? 1 : 0, privacy: .public) live=\(d.liveCount, privacy: .public) lastSeen=\(lastSeen, privacy: .public) peripherals=\(total, privacy: .public) accepted=\(acc, privacy: .public) filtered=\(total - acc, privacy: .public)")
    }

    /// The one and only light identity: the CoreBluetooth peripheral UUID.
    static func lightID(for uuid: UUID) -> String { "ble-" + uuid.uuidString.lowercased() }

    // MARK: - Public control API (called by DeviceStore)

    /// LEDnetWF transport wrapper (version 0, single segment): every command
    /// to FF01 MUST be wrapped — raw bytes are ignored by this profile.
    /// [0x00 header][seq][0x80 0x00 frag][len BE][len+1][cmdId 10/11][payload]
    private func transport(_ command: [UInt8], expectsResponse: Bool = false) -> [UInt8] {
        seq = seq &+ 1
        let len = command.count
        return [0x00, seq, 0x80, 0x00,
                UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF),
                UInt8((len + 1) & 0xFF), expectsResponse ? 10 : 11] + command
    }

    private func checksummed(_ command: [UInt8]) -> [UInt8] {
        command + [command.reduce(0, +) & 0xFF]
    }

    private func clamped(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 255)) }

    public func setPower(id: String, on: Bool) {
        // VERIFIED packet (Codex live test on IOTWF31D, Bleak write with
        // response): payload = 3B 23|24 00*7 32 00 00 + checksum(sum).
        // Fixed field 0x32 per the integration's power builder.
        // Re-verified on IOTWFE6D (fw 10): on -> LAN readback power 0x23.
        let p: UInt8 = on ? 0x23 : 0x24
        var payload: [UInt8] = [0x3B, p, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00]
        payload.append(payload.reduce(0, +) & 0xFF)
        send(id: id, op: "power", command: payload)
    }

    /// Pure colour over BLE — the SAME 0x3B 0xA1 HSV packet as the WiFi path
    /// (bridge.py _briturn_hsv_packet), wrapped in the transport layer:
    /// 3B A1 {hue/2 0-180} {sat 0-100} {val 0-100} 00 00 00 00 1E 00 00 + checksum.
    /// VERIFIED live over BLE (IOTWFE6D, fw 10): red -> LAN readback rgb
    /// ff 00 00 mode f0; hue 330/s30/v100 -> rgb ff b3 d9. The old
    /// `E0 01 00 C1 ...` frame and the E0-prefixed `E0 01 00 3B A1 ...` form
    /// were both acknowledged but changed nothing.
    public func setColor(id: String, red: Int, green: Int, blue: Int) {
        let r = Double(clamped(red)), g = Double(clamped(green)), b = Double(clamped(blue))
        let maxC = max(r, g, b), minC = min(r, g, b)
        let bri = maxC == 0 ? 0 : maxC / 255.0 * 100.0
        let sat = maxC == 0 ? 0 : (maxC - minC) / maxC * 100.0
        var hue = 0.0
        if maxC != minC {
            let delta = maxC - minC
            if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        let hueByte = UInt8(min(max(Int((hue / 2).rounded()), 0), 180))
        send(id: id, op: "color", command: checksummed(
            [0x3B, 0xA1, hueByte, UInt8(sat.rounded()), UInt8(bri.rounded()),
             0x00, 0x00, 0x00, 0x00, 0x1E, 0x00, 0x00]))
    }

    private func percent(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 100)) }

    /// Real warm/cool white over BLE — the SAME 0x3B 0xB1 packet as the WiFi
    /// path (bridge.py _briturn_cct_packet): cct 0 = warm .. 100 = cool,
    /// brightness 0-100. 3B B1 00 00 00 {cct} {bright} 00 00 1E 00 00 + checksum.
    /// VERIFIED live over BLE (IOTWFE6D, fw 10): cct 0/b100 -> LAN warm ff
    /// cool 00; cct 100/b100 -> warm 00 cool ff.
    public func setCCT(id: String, cct: Int, brightness: Int) {
        send(id: id, op: "cct", command: checksummed(
            [0x3B, 0xB1, 0x00, 0x00, 0x00, percent(cct), percent(brightness),
             0x00, 0x00, 0x1E, 0x00, 0x00]))
    }

    /// Legacy warm-only white (0x31 ... 0x0F 0x0F). Verified live it still
    /// works (level 128 -> warm 7f) but cannot drive the cool channel; the
    /// store uses setCCT instead. Kept for API compatibility.
    public func setWhite(id: String, level: Int) {
        send(id: id, op: "white", command: checksummed(
            [0x31, 0, 0, 0, clamped(level), 0, 0x0F, 0x0F]))
    }

    /// Brightness 0-100 — the SAME 0x3B 0x01 packet as the WiFi path:
    /// 3B 01 00 00 {v} 00 {v} 00 00 00 00 00 + checksum. VERIFIED live over
    /// BLE: v50 in cool white -> LAN cool 7f, white balance kept. The legacy
    /// 0x47 frame was dropped: verified live it has no effect on fw 10.
    public func setBrightness(id: String, percent value: Int) {
        let p = percent(value)
        send(id: id, op: "brightness", command: checksummed(
            [0x3B, 0x01, 0x00, 0x00, p, 0x00, p, 0x00, 0x00, 0x00, 0x00, 0x00]))
    }

    /// Local echo suppression is the STORE's job; this reports the latest
    /// wire state so the store can reconcile.
    public func state(for id: String) -> DeviceStore.BriturnState? {
        states[id]
    }

    // MARK: - Internals

    /// True when this run has discovered a peripheral for `id` (stale persisted entries are not live).
    func hasPeripheral(id: String) -> Bool { peripherals[id] != nil }

    private func label(_ peripheral: CBPeripheral) -> String {
        Self.lightID(for: peripheral.identifier)
    }

    private func send(id: String, op: String, command: [UInt8]) {
        let wrapped = transport(command)
        AppLog.ble.notice("MyHome: BLE cmd id=\(id, privacy: .public) op=\(op, privacy: .public) bytes=\(wrapped.count, privacy: .public) head=\(BLEWire.hexPrefix(command), privacy: .public)")
        guard let peripheral = peripherals[id] else {
            AppLog.ble.error("MyHome: BLE drop id=\(id, privacy: .public) op=\(op, privacy: .public) reason=no-live-peripheral")
            return
        }
        let key = peripheral.identifier
        if peripheral.state == .connected, notifyReady[key] == true, let writeChar = writeChars[key] {
            write(wrapped, op: op, to: peripheral, characteristic: writeChar)
            scheduleDisconnect(peripheral)
            return
        }
        connectAndThen(peripheral) { [weak self] failure in
            guard let self else { return }
            if let failure {
                AppLog.ble.error("MyHome: BLE drop id=\(id, privacy: .public) op=\(op, privacy: .public) reason=\(failure, privacy: .public)")
                return
            }
            guard peripheral.state == .connected, let writeChar = self.writeChars[key] else {
                AppLog.ble.error("MyHome: BLE drop id=\(id, privacy: .public) op=\(op, privacy: .public) reason=no-write-char-after-connect state=\(peripheral.state.rawValue, privacy: .public)")
                return
            }
            self.write(wrapped, op: op, to: peripheral, characteristic: writeChar)
        }
    }

    private func write(_ bytes: [UInt8], op: String, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let props = BLEWire.describe(characteristic.properties)
        guard let type = BLEWire.writeType(for: characteristic.properties) else {
            AppLog.ble.error("MyHome: BLE drop id=\(self.label(peripheral), privacy: .public) op=\(op, privacy: .public) reason=char-not-writable char=\(characteristic.uuid.uuidString, privacy: .public) props=\(props, privacy: .public)")
            return
        }
        let typeName = type == .withResponse ? "withResponse" : "withoutResponse"
        AppLog.ble.notice("MyHome: BLE write id=\(self.label(peripheral), privacy: .public) op=\(op, privacy: .public) char=\(characteristic.uuid.uuidString, privacy: .public) type=\(typeName, privacy: .public) len=\(bytes.count, privacy: .public) props=\(props, privacy: .public)")
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)
    }

    private func scheduleDisconnect(_ peripheral: CBPeripheral) {
        let key = peripheral.identifier
        disconnectTasks[key]?.cancel()
        disconnectTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.disconnectDelay)
            guard !Task.isCancelled, let self, self.connectRequests[key]?.isEmpty ?? true else { return }
            AppLog.ble.notice("MyHome: BLE idle disconnect id=\(self.label(peripheral), privacy: .public)")
            self.notifyReady[key] = false
            self.central.cancelPeripheralConnection(peripheral)
        }
    }

    private func connectAndThen(_ peripheral: CBPeripheral, _ after: @escaping (String?) -> Void) {
        let key = peripheral.identifier
        disconnectTasks[key]?.cancel()
        connectRequests[key, default: []].append(after)
        let pending = connectRequests[key]?.count ?? 0
        let id = label(peripheral)
        switch peripheral.state {
        case .connected where notifyReady[key] == true:
            finishConnect(peripheral, failure: nil)
        case .connected:
            // Connected but discovery never finished (or failed): redo it
            // rather than waiting for a notify-ready that will never come.
            AppLog.ble.notice("MyHome: BLE connected-not-ready id=\(id, privacy: .public) pending=\(pending, privacy: .public) -> rediscover")
            peripheral.delegate = self
            peripheral.discoverServices([BLEWire.service])
            armConnectTimeout(peripheral)
        case .connecting:
            AppLog.ble.notice("MyHome: BLE connect in progress id=\(id, privacy: .public) pending=\(pending, privacy: .public)")
        default:
            AppLog.ble.notice("MyHome: BLE connect requested id=\(id, privacy: .public) state=\(peripheral.state.rawValue, privacy: .public) pending=\(pending, privacy: .public)")
            central.connect(peripheral)
            armConnectTimeout(peripheral)
        }
    }

    private func armConnectTimeout(_ peripheral: CBPeripheral) {
        let key = peripheral.identifier
        connectTimeouts[key]?.cancel()
        connectTimeouts[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectTimeoutNanos)
            guard !Task.isCancelled, let self, self.notifyReady[key] != true else { return }
            AppLog.ble.error("MyHome: BLE connect timeout id=\(self.label(peripheral), privacy: .public) state=\(peripheral.state.rawValue, privacy: .public) (link held by another central, e.g. the phone app?)")
            self.central.cancelPeripheralConnection(peripheral)
            self.finishConnect(peripheral, failure: "connect-timeout")
        }
    }

    /// Drain every queued action for this peripheral exactly once.
    private func finishConnect(_ peripheral: CBPeripheral, failure: String?) {
        let key = peripheral.identifier
        connectTimeouts[key]?.cancel()
        connectTimeouts[key] = nil
        let callbacks = connectRequests[key] ?? []
        connectRequests[key] = nil
        callbacks.forEach { $0(failure) }
        // Re-arm the idle disconnect: the connect path cancelled it, and
        // without this the link stayed up forever (blocking the phone app).
        if failure == nil { scheduleDisconnect(peripheral) }
    }

    private func resetLink(_ peripheral: CBPeripheral) {
        let key = peripheral.identifier
        notifyReady[key] = false
        writeChars[key] = nil
        disconnectTasks[key]?.cancel()
        disconnectTasks[key] = nil
    }

    /// Decode the ZengGe v7 manufacturer block. Verified live: with company
    /// id included (CoreBluetooth), POWER sits at byte 3 (0x23 on / 0x24 off).
    /// Only power is trusted here — colour offsets vary by firmware and painted
    /// garbage once already. r/g/b are decoded only when sub_mode is 0xF0
    /// (RGB active); otherwise the state is treated as non-colour.
    private func decodeState(_ id: String, mfr: Data, hasServiceData: Bool, name: String) {
        let b = [UInt8](mfr)
        guard b.count >= 12 else { return }
        let stateOffset = (hasServiceData && b[1] >= 7) ? 3 : 14
        guard b.count >= stateOffset + 11 else { return }
        let s = Array(b[stateOffset...])
        let on = s[0] == 0x23
        let subMode = s[2]
        let r = Int(s[4]), g = Int(s[5]), bl = Int(s[6])
        let isWhite = subMode == 0x0F
        let rgbActive = subMode == 0xF0 || (!isWhite && !(r == 0 && g == 0 && bl == 0))
        let state = DeviceStore.BriturnState(
            on: on,
            rawPower: Int(s[0]),
            mode: Int(s[1]),
            r: (rgbActive && !isWhite) ? r : 0,
            g: (rgbActive && !isWhite) ? g : 0,
            b: (rgbActive && !isWhite) ? bl : 0,
            w: rgbActive ? 0 : Int(s[3])
        )
        states[id] = state
        rawStates[id] = state
    }

    /// "<companyId hex>/<payload length>" of the advertised manufacturer data, or "none".
    static func mfrSummary(_ adv: [String: Any]) -> String {
        let raw = adv[CBAdvertisementDataManufacturerDataKey]
        if let all = raw as? Data, all.count >= 2 {
            let company = Int(all[all.startIndex]) | (Int(all[all.startIndex + 1]) << 8)
            return String(format: "%04x/%d", company, all.count - 2)
        }
        if let dict = raw as? [AnyHashable: Data], let (k, v) = dict.first, let company = k as? Int {
            return String(format: "%04x/%d", company, v.count)
        }
        return "none"
    }

    /// Registers a discovered light under its peripheral-UUID id and decodes
    /// state. Returns the id and whether it is new this run.
    @discardableResult
    func noteLight(uuid: UUID, name: String, rssi: Int, mfr: Data, hasServiceData: Bool) -> (id: String, isNew: Bool) {
        let id = Self.lightID(for: uuid)
        let isNew = !lights.contains { $0.id == id }
        if isNew {
            lights.append(BLELight(id: id, name: name, rssi: rssi))
            lights.sort { $0.name < $1.name }
        }
        if !mfr.isEmpty {
            decodeState(id, mfr: mfr, hasServiceData: hasServiceData, name: name)
        }
        return (id, isNew)
    }

    private func isZenggeMfrKey(_ key: Int) -> Bool {
        (0x5A00...0x5AFF).contains(key)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isBluetoothOn = central.state == .poweredOn
        var d = diagnostics
        d.authorization = BLEAuthorization(CBCentralManager.authorization)
        d.state = BLEPowerState(central.state)
        guard isBluetoothOn else {
            d.isScanning = false
            diagnostics = d
            logSummary()
            return
        }
        // Duplicate reports ON: live state comes from repeated advertisements.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        d.isScanning = central.isScanning
        diagnostics = d
        logSummary()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? ""
        let accepted = name.hasPrefix("IOTWF") || name.hasPrefix("LEDnetWF") || name.hasPrefix("IOTBT")
        // Pre-filter log: every peripheral once per run, whatever its name.
        if advertUUIDsSeen.insert(peripheral.identifier).inserted {
            AppLog.ble.notice("MyHome: BLE adv uuid=\(peripheral.identifier.uuidString.lowercased(), privacy: .public) name=\(localName ?? "", privacy: .public) periphName=\(peripheral.name ?? "", privacy: .public) rssi=\(RSSI.intValue, privacy: .public) mfr=\(Self.mfrSummary(advertisementData), privacy: .public) accepted=\(accepted, privacy: .public)")
        }
        guard accepted else { return }
        advertUUIDsAccepted.insert(peripheral.identifier)

        var mfr = Data()
        var hasServiceData = false
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let sd = serviceData[CBUUID(string: "0000FFFF-0000-1000-8000-00805F9B34FB")], sd.count >= 16 {
            hasServiceData = true
        }
        if let all = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, all.count >= 2 {
            // raw AD blob includes the company id at the start
            mfr = all.count >= 29 ? all.subdata(in: 2..<all.count) : all
        }
        for (key, value) in (advertisementData[CBAdvertisementDataManufacturerDataKey] as? [AnyHashable: Data]) ?? [:] {
            if let keyNumber = key as? Int, isZenggeMfrKey(keyNumber) { mfr = value }
        }

        let (id, isNew) = noteLight(uuid: peripheral.identifier, name: name, rssi: RSSI.intValue,
                                    mfr: mfr, hasServiceData: hasServiceData)
        peripherals[id] = peripheral
        if isNew { AppLog.ble.notice("MyHome: BLE live peripheral id=\(id, privacy: .public) name=\(name, privacy: .public)") }
        diagnostics.liveCount = peripherals.count
        diagnostics.lastDiscovery = Date()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        AppLog.ble.error("MyHome: BLE didFailToConnect id=\(self.label(peripheral), privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        resetLink(peripheral)
        finishConnect(peripheral, failure: "connect-failed")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let pending = connectRequests[peripheral.identifier]?.count ?? 0
        AppLog.ble.notice("MyHome: BLE didDisconnect id=\(self.label(peripheral), privacy: .public) pending=\(pending, privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        resetLink(peripheral)
        if pending > 0 { finishConnect(peripheral, failure: "disconnected-before-ready") }
    }
}

extension BLEManager: CBPeripheralDelegate {
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        AppLog.ble.notice("MyHome: BLE didConnect id=\(self.label(peripheral), privacy: .public)")
        peripheral.delegate = self
        peripheral.discoverServices([BLEWire.service])
    }

    private func failDiscovery(_ peripheral: CBPeripheral, reason: String) {
        AppLog.ble.error("MyHome: BLE discovery failed id=\(self.label(peripheral), privacy: .public) reason=\(reason, privacy: .public)")
        central.cancelPeripheralConnection(peripheral)
        resetLink(peripheral)
        finishConnect(peripheral, failure: reason)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        let uuids = services.map { $0.uuid.uuidString }.joined(separator: ",")
        AppLog.ble.notice("MyHome: BLE services id=\(self.label(peripheral), privacy: .public) uuids=[\(uuids, privacy: .public)] error=\(error?.localizedDescription ?? "none", privacy: .public)")
        if let error {
            failDiscovery(peripheral, reason: "services-error " + error.localizedDescription)
            return
        }
        guard !services.isEmpty else {
            failDiscovery(peripheral, reason: "no-FFFF-service")
            return
        }
        for service in services {
            peripheral.discoverCharacteristics([BLEWire.writeChar, BLEWire.notifyChar], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let key = peripheral.identifier
        let chars = service.characteristics ?? []
        let summary = chars.map { "\($0.uuid.uuidString)(\(BLEWire.describe($0.properties)))" }.joined(separator: ",")
        AppLog.ble.notice("MyHome: BLE characteristics id=\(self.label(peripheral), privacy: .public) service=\(service.uuid.uuidString, privacy: .public) chars=[\(summary, privacy: .public)] error=\(error?.localizedDescription ?? "none", privacy: .public)")
        if let error {
            failDiscovery(peripheral, reason: "characteristics-error " + error.localizedDescription)
            return
        }
        var notifyChar: CBCharacteristic?
        for characteristic in chars {
            if characteristic.uuid == BLEWire.writeChar { writeChars[key] = characteristic }
            if characteristic.uuid == BLEWire.notifyChar { notifyChar = characteristic }
        }
        guard writeChars[key] != nil else {
            failDiscovery(peripheral, reason: "no-FF01-write-char")
            return
        }
        if let notifyChar {
            peripheral.setNotifyValue(true, for: notifyChar)
        } else {
            // No FF02: nothing would ever report notify-ready, so the queue
            // used to strand. Writes do not need notifications.
            AppLog.ble.notice("MyHome: BLE no FF02 notify char id=\(self.label(peripheral), privacy: .public) -> ready without notify")
            notifyReady[key] = true
            finishConnect(peripheral, failure: nil)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLEWire.notifyChar else { return }
        let key = peripheral.identifier
        AppLog.ble.notice("MyHome: BLE notify id=\(self.label(peripheral), privacy: .public) enabled=\(characteristic.isNotifying ? 1 : 0, privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        // A notify failure used to strand every queued command; the write
        // characteristic is usable regardless, so proceed when we have it.
        guard writeChars[key] != nil else {
            failDiscovery(peripheral, reason: "notify-without-write-char")
            return
        }
        notifyReady[key] = true
        finishConnect(peripheral, failure: nil)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            AppLog.ble.error("MyHome: BLE didWrite id=\(self.label(peripheral), privacy: .public) char=\(characteristic.uuid.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        } else {
            AppLog.ble.notice("MyHome: BLE didWrite id=\(self.label(peripheral), privacy: .public) char=\(characteristic.uuid.uuidString, privacy: .public) ok")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, data.count >= 8 else { return }
        let payload = [UInt8](data)[8...]
        // JSON-wrapped or binary payloads; either way the hex state frame
        // starts with 81 — decode power/mode/rgb the same as the WiFi path.
        guard payload.first == 0x81, payload.count >= 14 else { return }
        let id = peripherals.first { $0.value == peripheral }?.key ?? ""
        guard !id.isEmpty else { return }
        let on = payload[2] == 0x23
        states[id] = DeviceStore.BriturnState(
            on: on,
            rawPower: Int(payload[2]),
            mode: Int(payload[3]),
            r: Int(payload[6]),
            g: Int(payload[7]),
            b: Int(payload[8]),
            w: Int(payload[5])
        )
    }
}

/// Pure GATT helpers for the LEDnetWF profile (unit-tested).
enum BLEWire {
    static let service = CBUUID(string: "FFFF")
    static let writeChar = CBUUID(string: "FF01")
    static let notifyChar = CBUUID(string: "FF02")
    /// Bytes shown in logs; never the full payload.
    static let logPrefixBytes = 4

    /// Prefer acknowledged writes (so didWriteValueFor reports errors); fall
    /// back to write-without-response; nil when the char is not writable.
    static func writeType(for properties: CBCharacteristicProperties) -> CBCharacteristicWriteType? {
        if properties.contains(.write) { return .withResponse }
        if properties.contains(.writeWithoutResponse) { return .withoutResponse }
        return nil
    }

    static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeNoResp"),
            (.notify, "notify"), (.indicate, "indicate")
        ]
        let found = names.filter { properties.contains($0.0) }.map { $0.1 }
        return found.isEmpty ? "none" : found.joined(separator: "|")
    }

    static func hexPrefix(_ bytes: [UInt8]) -> String {
        bytes.prefix(logPrefixBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

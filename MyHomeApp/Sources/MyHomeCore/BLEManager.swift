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
    public let id: String            // "ble-<mac>"
    public let name: String
    public let rssi: Int
}

@MainActor
public final class BLEManager: NSObject, ObservableObject {
    public static let shared = BLEManager()

    @Published public private(set) var lights: [BLELight] = []
    /// Latest advertisement-decoded state per BLE light id, shared with the
    /// store's briturnStatus cache so cards/pickers treat BLE and WiFi alike.
    @Published public private(set) var states: [String: DeviceStore.BriturnState] = [:]
    @Published public private(set) var isBluetoothOn = false

    private var central: CBCentralManager!
    private var peripherals: [String: CBPeripheral] = [:]   // id -> peripheral
    /// CoreBluetooth hides the MAC; our ids come from advertisement decoding.
    /// Every per-characteristic lookup must go through this map, or the
    /// write-char lookup misses and commands silently never send.
    private var bleIDByPeripheralUUID: [UUID: String] = [:]
    private var rawStates: [String: DeviceStore.BriturnState] = [:]
    private var connectRequests: [String: [(Result<Void, NSError>) -> Void]] = [:]
    private var writeChars: [String: CBCharacteristic] = [:]
    private var notifyReady: [String: Bool] = [:]
    private var seq: UInt8 = 0
    /// Devices commanded recently keep their connection briefly so a slider
    /// burst doesn't reconnect per step.
    private var disconnectTasks: [String: Task<Void, Never>] = [:]
    private static let disconnectDelay: UInt64 = 2_500_000_000

    override private init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public control API (called by DeviceStore)

    public func setPower(id: String, on: Bool) {
        // Legacy 0x71 power works across observed firmware; 0x3B is the v5+
        // variant if 0x71 is ever ignored.
        send(id: id, command: [0x71, on ? 0x23 : 0x24, 0x0F])
    }

    public func setColor(id: String, red: Int, green: Int, blue: Int) {
        // 0x5A = RGBCW channels active, w/cw = 0 (pure colour — same
        // white-off rule as the WiFi path), 0x0F persist flag, checksum last.
        var cmd: [UInt8] = [0x31, clamped(red), clamped(green), clamped(blue), 0, 0, 0x5A, 0x0F]
        cmd.append(cmd.reduce(0, +) & 0xFF)
        send(id: id, command: cmd)
    }

    public func setBrightness(id: String, percent: Int) {
        // Standalone brightness: legacy 0x47 takes 0-255; modern 0x3B takes
        // percent. Send 0x3B primary (v9+), fall back harmless elsewhere.
        let p = clamped(percent)
        var modern: [UInt8] = [0x3B, 0x01, 0x00, 0x00, UInt8(p), 0x00, UInt8(p), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        modern.append(modern.reduce(0, +) & 0xFF)
        send(id: id, command: modern)
        var legacy: [UInt8] = [0x47, UInt8(max(1, Int(Double(p) * 2.55)))]
        legacy.append(legacy.reduce(0, +) & 0xFF)
        send(id: id, command: legacy)
    }

    /// Warm-white mode at the given level (0-255 on the white channel).
    public func setWhite(id: String, level: Int) {
        var cmd: [UInt8] = [0x31, 0, 0, 0, clamped(level), 0, 0x5A, 0x0F]
        cmd.append(cmd.reduce(0, +) & 0xFF)
        send(id: id, command: cmd)
    }

    /// Local echo suppression is the STORE's job; this reports the latest
    /// wire state so the store can reconcile.
    public func state(for id: String) -> DeviceStore.BriturnState? {
        states[id]
    }

    // MARK: - Internals

    private func clamped(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 255)) }

    /// LEDnetWF transport wrapper (version 0, single segment, no-response).
    private func transport(_ command: [UInt8]) -> [UInt8] {
        seq = seq &+ 1
        let len = command.count
        return [0x00, seq, 0x80, 0x00,
                UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF),
                UInt8((len + 1) & 0xFF), 11] + command
    }

    private func send(id: String, command: [UInt8]) {
        guard let peripheral = peripherals[id] else { return }
        scheduleDisconnect(id: id)
        if notifyReady[id] == true, let writeChar = writeChars[id] {
            peripheral.writeValue(Data(transport(command)), for: writeChar, type: .withoutResponse)
        } else {
            connectAndThen(id: id) { [weak self] in
                guard let self, let writeChar = self.writeChars[id] else { return }
                peripheral.writeValue(Data(self.transport(command)), for: writeChar, type: .withoutResponse)
            }
        }
    }

    private func scheduleDisconnect(id: String) {
        disconnectTasks[id]?.cancel()
        disconnectTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.disconnectDelay)
            guard let self, let p = self.peripherals[id], self.connectRequests[id] == nil || self.connectRequests[id]?.isEmpty == true else { return }
            self.central.cancelPeripheralConnection(p)
            self.notifyReady[id] = false
        }
    }

    private func connectAndThen(id: String, _ after: @escaping () -> Void) {
        disconnectTasks[id]?.cancel()
        connectRequests[id, default: []].append { _ in after() }
        if let p = peripherals[id], p.state == .connected, notifyReady[id] == true {
            // Already up: drain immediately.
            let callbacks = connectRequests[id] ?? []
            connectRequests[id] = []
            callbacks.forEach { $0(.success(())) }
        } else if let p = peripherals[id] {
            central.connect(p)
        }
    }

    /// Decode the ZengGe manufacturer-data block (company 0x5A**) into state.
    /// Format B (bleak-style, company id as dictionary key):
    ///   [0] sta [1] ble_ver [2-7] mac [8-9] product [10] fw [11] led_ver
    ///   [12] check_key_flag [13] fw_flag [14] power [15] mode [16] sub_mode
    ///   [17] white/value [18-20] r g b [21] ww [22] led_ver2 [23] cw
    /// v7+ devices with service data report state from offset 3 instead.
    private func decodeState(_ id: String, mfr: Data, hasServiceData: Bool, name: String) {
        let b = [UInt8](mfr)
        guard b.count >= 24 else { return }
        let stateOffset = (hasServiceData && b[1] >= 7) ? 3 : 14
        guard b.count >= stateOffset + 11 else { return }
        let s = Array(b[stateOffset...])
        let on = s[0] == 0x23
        let subMode = s[2]
        let r = Int(s[4]), g = Int(s[5]), bl = Int(s[6])
        let isWhite = subMode == 0x0F || (r == 0 && g == 0 && bl == 0)
        let state = DeviceStore.BriturnState(
            on: on,
            rawPower: Int(s[0]),
            mode: Int(s[1]),
            r: isWhite ? 0 : Int(s[4]),
            g: isWhite ? 0 : Int(s[5]),
            b: isWhite ? 0 : Int(s[6]),
            w: Int(s[3])
        )
        states[id] = state
        rawStates[id] = state
    }

    private func macFromMfr(_ mfr: Data) -> String? {
        let b = [UInt8](mfr)
        guard b.count >= 8 else { return nil }
        // bytes 2-7 hold the MAC (reversed on air)
        let mac = b[2...7].reversed().map { String(format: "%02x", $0) }.joined()
        return mac.count == 12 ? mac : nil
    }

    private func isZenggeMfrKey(_ key: Int) -> Bool {
        (0x5A00...0x5AFF).contains(key)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isBluetoothOn = central.state == .poweredOn
        guard isBluetoothOn else { return }
        // Duplicate reports ON: live state comes from repeated advertisements.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.hasPrefix("IOTWF") || name.hasPrefix("LEDnetWF") || name.hasPrefix("IOTBT") else { return }

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

        let id: String
        if let m = macFromMfr(mfr) {
            id = "ble-" + m
        } else {
            id = "ble-" + peripheral.identifier.uuidString.lowercased()
        }

        let isNew = peripherals[id] == nil
        peripherals[id] = peripheral
        bleIDByPeripheralUUID[peripheral.identifier] = id
        if isNew || lights.first(where: { $0.id == id }) == nil {
            lights.append(BLELight(id: id, name: name, rssi: RSSI.intValue))
            lights.sort { $0.name < $1.name }
        }
        if !mfr.isEmpty {
            decodeState(id, mfr: mfr, hasServiceData: hasServiceData, name: name)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: "FFFF")])
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics([CBUUID(string: "FF01"), CBUUID(string: "FF02")], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let bleID = bleIDByPeripheralUUID[peripheral.identifier] ?? peripheral.identifier.uuidString
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid.uuidString.suffix(4).uppercased() {
            case "FF01": writeChars[bleID] = characteristic
            case "FF02":
                peripheral.setNotifyValue(true, for: characteristic)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid.uuidString.suffix(4).uppercased() == "FF02", error == nil else { return }
let ownerID = bleIDByPeripheralUUID[peripheral.identifier] ?? peripheral.identifier.uuidString
        notifyReady[ownerID] = true
        let callbacks = connectRequests[ownerID] ?? []
        connectRequests[ownerID] = []
        callbacks.forEach { $0(.success(())) }
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

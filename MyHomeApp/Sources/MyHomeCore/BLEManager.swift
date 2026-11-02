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
import Combine
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

    // CoreBluetooth runs on BLECentralCore's own serial queue; these mirrors
    // are updated from its coalesced batches (at most every
    // BLECentralCore.publishInterval) and only when a value really changed.
    @Published public private(set) var lights: [BLELight] = []
    /// Latest advertisement-decoded state per BLE light id, shared with the
    /// store's briturnStatus cache so cards/pickers treat BLE and WiFi alike.
    @Published public private(set) var states: [String: DeviceStore.BriturnState] = [:]
    @Published public private(set) var isBluetoothOn = false
    /// Fires once per coalesced batch while adverts are heard (no payload),
    /// so the store can re-reconcile pending intents without a state change.
    public let advertTick = PassthroughSubject<Void, Never>()
    /// Seconds between BLE summary logs; also the unit for BLE state staleness.
    nonisolated public static let summaryInterval: TimeInterval = 30

    let core: BLECentralCore

    /// Read under the core's lock: always current, never published per advert.
    public var diagnostics: BLEDiagnostics { core.diagnostics }

    init(startCentral: Bool) {
        core = BLECentralCore(startCentral: startCentral, summaryInterval: Self.summaryInterval)
        super.init()
        core.onFlush = { [weak self] flush in
            Task { @MainActor [weak self] in self?.apply(flush) }
        }
    }

    /// Applies one coalesced batch: compare before assign, so equal content
    /// never fires objectWillChange.
    func apply(_ flush: BLEFlush) {
        if let value = flush.lights, value != lights { lights = value }
        if let value = flush.states, value != states { states = value }
        if let value = flush.isBluetoothOn, value != isBluetoothOn { isBluetoothOn = value }
        advertTick.send(())
    }

    /// The one and only light identity: the CoreBluetooth peripheral UUID.
    nonisolated static func lightID(for uuid: UUID) -> String { BLECentralCore.lightID(for: uuid) }

    /// Tuya BLE identifiers (feasibility logging only; no behaviour depends on them).
    nonisolated static var tuyaNamePrefixes: [String] { BLEAdvert.tuyaNamePrefixes }
    nonisolated static var tuyaMfrCompanyID: Int { BLEAdvert.tuyaMfrCompanyID }
    nonisolated static var tuyaServiceUUIDs: Set<CBUUID> { BLEAdvert.tuyaServiceUUIDs }

    nonisolated static func isTuyaAdvert(name: String, mfrCompanyID: Int?, serviceUUIDs: [CBUUID]) -> Bool {
        BLEAdvert.isTuyaAdvert(name: name, mfrCompanyID: mfrCompanyID, serviceUUIDs: serviceUUIDs)
    }

    nonisolated static func hexString(_ data: Data) -> String { BLEAdvert.hexString(data) }

    nonisolated static func mfrSummary(_ adv: [String: Any]) -> String { BLEAdvert.mfrSummary(adv) }

    // MARK: - Public control API (called by DeviceStore; sends hop to the BLE queue)

    private func checksummed(_ command: [UInt8]) -> [UInt8] {
        command + [command.reduce(0, &+)]
    }

    private func clamped(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 255)) }

    public func setPower(id: String, on: Bool) {
        // VERIFIED packet (Codex live test on IOTWF31D, Bleak write with
        // response): payload = 3B 23|24 00*7 32 00 00 + checksum(sum).
        // Fixed field 0x32 per the integration's power builder.
        // Re-verified on IOTWFE6D (fw 10): on -> LAN readback power 0x23.
        let p: UInt8 = on ? 0x23 : 0x24
        var payload: [UInt8] = [0x3B, p, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00]
        payload.append(payload.reduce(0, &+))
        core.send(id: id, op: "power", command: payload)
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
        core.send(id: id, op: "color", command: checksummed(
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
        core.send(id: id, op: "cct", command: checksummed(
            [0x3B, 0xB1, 0x00, 0x00, 0x00, percent(cct), percent(brightness),
             0x00, 0x00, 0x1E, 0x00, 0x00]))
    }

    /// Legacy warm-only white (0x31 ... 0x0F 0x0F). Verified live it still
    /// works (level 128 -> warm 7f) but cannot drive the cool channel; the
    /// store uses setCCT instead. Kept for API compatibility.
    public func setWhite(id: String, level: Int) {
        core.send(id: id, op: "white", command: checksummed(
            [0x31, 0, 0, 0, clamped(level), 0, 0x0F, 0x0F]))
    }

    /// Brightness 0-100 — the SAME 0x3B 0x01 packet as the WiFi path:
    /// 3B 01 00 00 {v} 00 {v} 00 00 00 00 00 + checksum. VERIFIED live over
    /// BLE: v50 in cool white -> LAN cool 7f, white balance kept. The legacy
    /// 0x47 frame was dropped: verified live it has no effect on fw 10.
    public func setBrightness(id: String, percent value: Int) {
        let p = percent(value)
        core.send(id: id, op: "brightness", command: checksummed(
            [0x3B, 0x01, 0x00, 0x00, p, 0x00, p, 0x00, 0x00, 0x00, 0x00, 0x00]))
    }

    /// Local echo suppression is the STORE's job; this reports the latest
    /// wire state so the store can reconcile.
    public func state(for id: String) -> DeviceStore.BriturnState? {
        states[id]
    }

    // MARK: - Internals

    /// True when this run has discovered a peripheral for `id` (stale persisted entries are not live).
    func hasPeripheral(id: String) -> Bool { core.hasPeripheral(id: id) }

    /// When the latest advert for `id` was heard this run (nil if never).
    func lastAdvert(for id: String) -> Date? { core.lastAdvert(for: id) }

    /// Registers a discovered light under its peripheral-UUID id and decodes
    /// state, then applies the resulting batch immediately (test seam; the
    /// live path goes through the core's coalesced flush).
    @discardableResult
    func noteLight(uuid: UUID, name: String, rssi: Int, mfr: Data, hasServiceData: Bool) -> (id: String, isNew: Bool) {
        let core = self.core
        let result = core.queue.sync {
            core.noteLight(uuid: uuid, name: name, rssi: rssi, mfr: mfr, hasServiceData: hasServiceData)
        }
        apply(core.queue.sync { core.takeFlush() })
        return result
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

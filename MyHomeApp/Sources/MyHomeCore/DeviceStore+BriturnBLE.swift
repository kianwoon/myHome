// Briturn BLE command fan-out, shared by the BLE-only route and the WiFi ->
// BLE fallback so both send exactly what the mobile app sends (the same
// 0x3B packets as the WiFi path; see BLEManager for the live verification).

import Foundation

extension DeviceStore {
    /// Default CCT brightness when a CCT set carries no brightness — mirrors
    /// bridge.py (BRITURN_CCT_MAX).
    static let briturnBLEDefaultCCTBrightness = 100
    /// Full scale of one wire colour channel, and of a brightness percent.
    static let briturnChannelMax = 255
    static let briturnPercentMax = 100

    /// Optimistic colour for a brightness-only write in colour mode: the bulb
    /// (0x3B 0x01) rescales its colour so the PEAK channel lands on `percent`,
    /// and every card derives brightness from that peak. Scaled per light from
    /// its OWN peak, so group members all paint the same brightness.
    static func briturnScaled(_ rgb: (r: Int, g: Int, b: Int), toPercent percent: Int) -> (r: Int, g: Int, b: Int) {
        let peak = max(rgb.r, rgb.g, rgb.b, 1)
        let target = Double(min(max(percent, 0), briturnPercentMax)) * Double(briturnChannelMax) / Double(briturnPercentMax)
        let scale = target / Double(peak)
        func channel(_ v: Int) -> Int { min(Int((Double(v) * scale).rounded()), briturnChannelMax) }
        return (channel(rgb.r), channel(rgb.g), channel(rgb.b))
    }

    /// Stale-LAN rule for writes: a light with an address whose reachability
    /// says Bluetooth (cloud offline + live advert) must not detour through the
    /// bridge and the cloud first — every detour was 0.5-5 s per command.
    func routesWriteOverBLEFirst(_ device: Device) -> Bool {
        device.hasAddress && reachability(for: device) == .bluetooth && bleKey(for: device) != nil
    }

    /// Returns false (and sends nothing) when no live peripheral exists for `key`.
    @discardableResult
    func sendBriturnBLE(
        key: String, on: Bool?, color: (red: Int, green: Int, blue: Int)?,
        brightness: Int?, white: Bool, cct: Int?
    ) -> Bool {
        let live = isBLEKeyLive(key)
        AppLog.store.notice("MyHome: Briturn route=BLE key=\(key, privacy: .public) peripheralLive=\(live ? "yes" : "no", privacy: .public)")
        guard live else { return false }
        if let hook = briturnBLESendHook { hook(key, on); return true }
        let ble = BLEManager.shared
        if let on = on { ble.setPower(id: key, on: on) }
        if let color = color { ble.setColor(id: key, red: color.red, green: color.green, blue: color.blue) }
        if white || cct != nil {
            // Real warm/cool channels. `white: true` without a cct means plain
            // warm white (cct 0). Brightness folds into the CCT packet, like
            // the WiFi path, so no separate brightness frame is sent.
            ble.setCCT(id: key, cct: cct ?? 0,
                       brightness: brightness ?? Self.briturnBLEDefaultCCTBrightness)
        } else if let brightness = brightness {
            ble.setBrightness(id: key, percent: brightness)
        }
        return true
    }
}

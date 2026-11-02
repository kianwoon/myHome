// Briturn BLE command fan-out, shared by the BLE-only route and the WiFi ->
// BLE fallback so both send exactly what the mobile app sends (the same
// 0x3B packets as the WiFi path; see BLEManager for the live verification).

import Foundation

extension DeviceStore {
    /// Default CCT brightness when a CCT set carries no brightness — mirrors
    /// bridge.py (BRITURN_CCT_MAX).
    static let briturnBLEDefaultCCTBrightness = 100

    /// Returns false (and sends nothing) when no live peripheral exists for `key`.
    @discardableResult
    func sendBriturnBLE(
        key: String, on: Bool?, color: (red: Int, green: Int, blue: Int)?,
        brightness: Int?, white: Bool, cct: Int?
    ) -> Bool {
        let live = isBLEKeyLive(key)
        NSLog("MyHome: Briturn route=BLE key=%@ peripheralLive=%@", key, live ? "yes" : "no")
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

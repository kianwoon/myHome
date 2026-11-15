// baseline-guard:allow new source file, no prior baseline
// The outcome of ONE Tuya dps write, carried by value. Callers that run
// several writes at once must read their own result, never the store's
// shared `errorText` (which the next write overwrites).
import Foundation

public enum SetDpsResult: Equatable {
    /// The bridge answered ok; `echo` is the dps the device reported back with
    /// THIS reply (nil when the reply carried none).
    case applied(echo: [String: DPSValue]?)
    /// The bridge answered with an error or the transport threw. `definite`
    /// is true only for an explicit rejection (bad id/dps); a timeout or a
    /// connection error is an unknown outcome.
    case failed(String, definite: Bool)
    /// Nothing was sent: the device has no network address. `bluetoothOnly`
    /// marks a device known only over Bluetooth, for which no Tuya write path
    /// exists.
    case noAddress(bluetoothOnly: Bool)

    public var ok: Bool {
        if case .applied = self { return true }
        return false
    }

    // allow-hardcode: user-facing error text.
    public static let noAddressText = "has no network address, so nothing was sent"
    public static let bluetoothOnlyText = "is only reachable over Bluetooth and MyHome has no Bluetooth control path for this device type; nothing was sent"

    public var message: String? {
        switch self {
        case .applied: return nil
        case .failed(let text, _): return text
        case .noAddress(let bluetoothOnly): return bluetoothOnly ? Self.bluetoothOnlyText : Self.noAddressText
        }
    }
}

extension DeviceStore {
    /// Bool form kept for existing callers (dashboard controls).
    @discardableResult
    public func setDps(
        _ device: Device,
        _ values: [String: Any],
        optimistic: [String: DPSValue] = [:]
    ) async -> Bool {
        await setDpsReporting(device, values, optimistic: optimistic).ok
    }
}

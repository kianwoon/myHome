// Bluetooth diagnostics: why a BLE command cannot reach a light. Pure types so
// the reason selection is unit-testable without CoreBluetooth hardware.

@preconcurrency import CoreBluetooth
import Foundation

public enum BLEAuthorization: String, Equatable {
    case notDetermined, restricted, denied, allowedAlways

    init(_ auth: CBManagerAuthorization) {
        switch auth {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .allowedAlways: self = .allowedAlways
        @unknown default: self = .notDetermined
        }
    }
}

public enum BLEPowerState: String, Equatable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn

    init(_ state: CBManagerState) {
        switch state {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }
}

public struct BLEDiagnostics: Equatable {
    public var authorization: BLEAuthorization = .notDetermined
    public var state: BLEPowerState = .unknown
    public var isScanning = false
    /// Peripherals discovered during THIS run (persisted history excluded).
    public var liveCount = 0
    public var lastDiscovery: Date?

    public init() {}
}

public enum BLEReason {
    public static let notSeen = "Bluetooth: light not seen recently — move closer or wait a moment"
    public static let permissionOff = "Bluetooth permission is off for MyHome — enable it in System Settings → Privacy & Security → Bluetooth"
    public static let permissionPending = "Waiting for Bluetooth permission — answer the system prompt"
    public static let bluetoothOff = "Bluetooth is off on this Mac"

    /// The real reason a light cannot be reached over Bluetooth.
    public static func message(authorization: BLEAuthorization, state: BLEPowerState,
                               scanning: Bool, liveCount: Int, lightLive: Bool) -> String {
        switch authorization {
        case .denied, .restricted: return permissionOff
        case .notDetermined: return permissionPending
        case .allowedAlways: break
        }
        switch state {
        case .unauthorized: return permissionOff
        case .poweredOff, .unsupported: return bluetoothOff
        case .unknown, .resetting, .poweredOn: break
        }
        if scanning, !lightLive, liveCount > 0 {
            return notSeen + " (\(liveCount) other light\(liveCount == 1 ? "" : "s") in range)"
        }
        return notSeen
    }

    public static func message(_ d: BLEDiagnostics, lightLive: Bool) -> String {
        message(authorization: d.authorization, state: d.state, scanning: d.isScanning,
                liveCount: d.liveCount, lightLive: lightLive)
    }
}

// KEF LS50 Wireless II — typed models (identity, input, power, state, errors,
// persisted record, tunables). Protocol details live in KEFClient; the wire
// vocabulary below comes from open-source reference clients and is PENDING
// confirmation on the user's speaker (see docs/KEF.md).
import Foundation

/// Sources the integration will offer. `unknown` keeps firmware values we have
/// not qualified representable; they are shown as "Unknown", never rewritten.
public enum KEFInput: Hashable, Sendable {
    case wifi, bluetooth, tv, optical, analog, usb
    case unknown(String)

    /// Wire strings (protocol constants).
    public var wireValue: String {
        switch self {
        case .wifi: return "wifi"
        case .bluetooth: return "bluetooth"
        case .tv: return "tv"
        case .optical: return "optic"
        case .analog: return "analog"
        case .usb: return "usb"
        case .unknown(let raw): return raw
        }
    }

    public init(wireValue: String) {
        switch wireValue.lowercased() {
        case "wifi": self = .wifi
        case "bluetooth": self = .bluetooth
        case "tv": self = .tv
        case "optic", "optical": self = .optical
        case "analog", "aux": self = .analog
        case "usb": self = .usb
        default: self = .unknown(wireValue)
        }
    }

    public var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .tv: return "TV"
        case .optical: return "Optical"
        case .analog: return "AUX"
        case .usb: return "USB"
        case .unknown: return "Unknown"
        }
    }

    /// Inputs selectable on LS50 Wireless II (reference-derived, pending device qualification).
    public static let selectable: [KEFInput] = [.wifi, .bluetooth, .tv, .optical, .analog, .usb]

    /// Words a person may say for this input.
    public var spokenNames: [String] {
        switch self {
        case .wifi: return ["wifi", "wi-fi", "wi fi", "streaming"]
        case .bluetooth: return ["bluetooth"]
        case .tv: return ["tv", "television", "hdmi"]
        case .optical: return ["optical", "optic", "toslink"]
        case .analog: return ["aux", "analog", "analogue"]
        case .usb: return ["usb"]
        case .unknown: return []
        }
    }

    public static func fromSpoken(_ text: String) -> KEFInput? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return selectable.first { $0.spokenNames.contains(lowered) }
    }
}

public enum KEFPower: Equatable, Sendable {
    case active, standby
    case unknown(String)
}

public struct KEFIdentity: Equatable, Codable, Sendable {
    public let model: String
    public let firmware: String
    /// Stable identity: primary MAC, lowercase hex without separators.
    public let macAddress: String

    public init(model: String, firmware: String, macAddress: String) {
        self.model = model
        self.firmware = firmware
        self.macAddress = macAddress
    }

    public var deviceID: String { "\(KEFProtocol.idPrefix)\(macAddress)" }
    public var isSupportedModel: Bool { KEFModel.isSupported(model) }
}

public enum KEFModel {
    /// Only LS50 Wireless II is in scope for the first release.
    public static let supportedMarkers = ["ls50w2", "ls50wii", "ls50wirelessii", "sp4025"]

    public static func isSupported(_ model: String) -> Bool {
        let flat = model.lowercased().filter { $0.isLetter || $0.isNumber }
        return supportedMarkers.contains { flat.hasPrefix($0) }
    }
}

/// One reading. A missing field stays nil: never zero / false / standby.
public struct KEFState: Equatable, Sendable {
    public var power: KEFPower?
    public var volume: Int?
    public var muted: Bool?
    public var input: KEFInput?
    /// Device-reported ceiling, when the speaker exposes one.
    public var maxVolume: Int?

    public init(power: KEFPower? = nil, volume: Int? = nil, muted: Bool? = nil,
                input: KEFInput? = nil, maxVolume: Int? = nil) {
        self.power = power
        self.volume = volume
        self.muted = muted
        self.input = input
        self.maxVolume = maxVolume
    }
}

/// A semantic speaker write (the KEF arm of CapabilityMap.WritePlan).
public enum KEFAction: Equatable, Hashable, Sendable {
    case power(Bool)
    case volume(Int)
    case mute(Bool)
    case input(KEFInput)

    public var control: KEFPendingControl {
        switch self {
        case .power: return .power
        case .volume: return .volume
        case .mute: return .mute
        case .input: return .input
        }
    }

    /// Volume, mute and input never run in standby (a source write would wake it).
    public var requiresActive: Bool {
        if case .power = self { return false }
        return true
    }

    /// Does a reading show this action's value? nil = the field is missing (cannot tell).
    public func matches(_ state: KEFState) -> Bool? {
        switch self {
        case .power(let on):
            switch state.power {
            case .active?: return on
            case .standby?: return !on
            default: return nil
            }
        case .volume(let value): return state.volume.map { $0 == value }
        case .mute(let value): return state.muted.map { $0 == value }
        case .input(let value): return state.input.map { $0 == value }
        }
    }
}

public enum KEFError: Error, Equatable, Sendable {
    case invalidAddress
    case unsupportedModel(String)
    case unsupportedInput(String)
    case authenticationRequired
    case timeout
    case unreachable
    case malformedResponse
    case rejected(Int)
    case standbyBlocksWrite
    case volumeOutOfRange(ClosedRange<Int>)

    public var message: String {
        switch self {
        case .invalidAddress: return "Enter a valid IPv4 address."
        case .unsupportedModel(let model): return "\(model.isEmpty ? "This speaker" : model) is not supported yet (LS50 Wireless II only)."
        case .unsupportedInput(let input): return "Input \(input) is not supported."
        case .authenticationRequired: return "The speaker needs setup before MyHome can control it."
        case .timeout: return "The speaker did not answer in time."
        case .unreachable: return "The speaker could not be reached."
        case .malformedResponse: return "The speaker sent a reply MyHome did not understand."
        case .rejected(let code): return "The speaker rejected the request (HTTP \(code))."
        case .standbyBlocksWrite: return "The speaker is in standby; turn it on first."
        case .volumeOutOfRange(let range): return "Volume must be \(range.lowerBound)…\(range.upperBound)."
        }
    }
}

/// Persisted, versioned local record (non-secret metadata only).
public struct KEFSpeakerRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var identity: KEFIdentity
    public var address: String
    public var name: String
    public var room: String

    public var id: String { identity.deviceID }

    public init(identity: KEFIdentity, address: String, name: String, room: String) {
        self.version = Self.currentVersion
        self.identity = identity
        self.address = address
        self.name = name
        self.room = room
    }
}

/// Tunables (spec §6). Same pattern as ControlConfig: named defaults, clamped
/// UserDefaults overrides, no bare literals in the control path.
public struct KEFConfig: Equatable, Sendable {
    public var requestTimeout: TimeInterval
    public var visibleRefreshInterval: TimeInterval
    public var backgroundRefreshInterval: TimeInterval
    public var backoffSchedule: [TimeInterval]
    public var backoffCap: TimeInterval
    public var port: Int
    public var volumeStep: Int
    public var volumeRange: ClosedRange<Int>
    public var readbackDelay: TimeInterval
    /// Keyboard/accessibility volume changes commit after this quiet period.
    public var commitDebounce: TimeInterval
    /// Wake/standby take 3–6 s to show in speakerStatus (observed): power readback polls this long.
    public var powerSettleTimeout: TimeInterval
    public var powerSettleInterval: TimeInterval

    public static let defaults = KEFConfig(
        requestTimeout: 3, visibleRefreshInterval: 15, backgroundRefreshInterval: 60,
        backoffSchedule: [30, 60, 120], backoffCap: 300, port: 80, volumeStep: 5,
        volumeRange: 0...100, readbackDelay: 0.6, commitDebounce: 0.4, powerSettleTimeout: 12, powerSettleInterval: 1)

    public static let requestTimeoutKey = "kefRequestTimeoutSeconds"
    public static let visibleRefreshKey = "kefVisibleRefreshSeconds"
    public static let backgroundRefreshKey = "kefBackgroundRefreshSeconds"
    public static let volumeStepKey = "kefVolumeStep"

    public static func fromDefaults(_ store: UserDefaults = .standard) -> KEFConfig {
        var config = defaults
        func seconds(_ key: String, _ fallback: TimeInterval, _ range: ClosedRange<TimeInterval>) -> TimeInterval {
            min(max(store.object(forKey: key) as? Double ?? fallback, range.lowerBound), range.upperBound)
        }
        config.requestTimeout = seconds(requestTimeoutKey, defaults.requestTimeout, 1...15)
        config.visibleRefreshInterval = seconds(visibleRefreshKey, defaults.visibleRefreshInterval, 5...300)
        config.backgroundRefreshInterval = max(seconds(backgroundRefreshKey, defaults.backgroundRefreshInterval, 30...900),
                                               defaults.backgroundRefreshInterval)
        config.volumeStep = min(max(store.object(forKey: volumeStepKey) as? Int ?? defaults.volumeStep, 1), 20)
        return config
    }

    /// Back-off delay after `failures` consecutive failures (0 → none).
    public func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let index = failures - 1
        return index < backoffSchedule.count ? backoffSchedule[index] : backoffCap
    }
}

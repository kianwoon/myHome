// Unified device-control API — semantic command model.
//
// A DeviceCommand says WHAT the user wants ("power on", "level 50%") without
// naming a dp, a transport or a vendor. CapabilityMap turns it into the exact
// write the dashboard would perform; DeviceController runs policy, executes
// through DeviceStore and verifies the published state.
import Foundation

/// Capability a device may expose, independent of transport and dp numbering.
public enum SemanticCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case power
    /// Percent level: brightness for lights, position for curtains, gear
    /// fraction for fans.
    case level
    case color
    /// Percent warm (0) → cool (100).
    case colorTemperature
    /// Enum dp (work_mode, mode …) set by its declared string value.
    case mode
    /// Gear 1…max (numeric fans) or small/middle/large (string fans).
    case fanSpeed
    case openClose
}

public enum CoverAction: String, CaseIterable, Codable, Hashable, Sendable {
    case open, close, stop
}

public struct RGB: Equatable, Hashable, Codable, Sendable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var tuple: (red: Int, green: Int, blue: Int) { (red, green, blue) }
}

/// A transport-agnostic command. Percent values are 0…100; fan speed is a gear.
public enum DeviceCommand: Equatable, Hashable, Sendable {
    case power(Bool)
    case level(Int)
    case color(RGB)
    case colorTemperature(Int)
    case mode(String)
    case fanSpeed(Int)
    case cover(CoverAction)

    public var capability: SemanticCapability {
        switch self {
        case .power: return .power
        case .level: return .level
        case .color: return .color
        case .colorTemperature: return .colorTemperature
        case .mode: return .mode
        case .fanSpeed: return .fanSpeed
        case .cover: return .openClose
        }
    }

    /// Commands that change many devices at once are "high impact" only by
    /// count; a single command is never high impact by itself.
    public var isStateChanging: Bool { true }
}

/// Where a request came from. Policy is origin-agnostic; the origin is kept
/// for logging and for the spoken reply style.
public enum CommandOrigin: String, Codable, Hashable, Sendable {
    case text, voice, siri, model, dashboard
}

/// Percent helpers shared by the capability map and the parsers.
public enum Percent {
    public static let range = 0...100

    public static func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Maps a percent onto a declared integer range, snapping to `step`.
    public static func scaled(_ percent: Int, to lower: Double, _ upper: Double, step: Double? = nil) -> Int {
        let fraction = Double(clamp(percent)) / Double(range.upperBound)
        var value = lower + fraction * (upper - lower)
        if let step = step, step > 0 {
            value = lower + ((value - lower) / step).rounded() * step
        }
        return Int(min(max(value, lower), upper).rounded())
    }

    /// Inverse of `scaled`: a raw dp value back to percent.
    public static func unscaled(_ value: Double, from lower: Double, _ upper: Double) -> Int {
        guard upper > lower else { return range.lowerBound }
        let fraction = (value - lower) / (upper - lower)
        return clamp(Int((fraction * Double(range.upperBound)).rounded()))
    }
}

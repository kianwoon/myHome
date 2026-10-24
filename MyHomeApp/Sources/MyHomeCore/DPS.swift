// baseline-guard:allow new source file, no prior baseline
import Foundation

/// Loose value for anything the device reports in a DPS map.
///
/// Tuya devices are inconsistent: a DP can arrive as a bool, a number, an
/// enum string, or even an array/object. Decoding never throws on shape, so
/// unexpected payloads fall through to a readable raw rendering instead of
/// crashing a force-cast.
public enum DPSValue: Codable, Hashable, CustomStringConvertible {
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DPSValue])
    case object([String: DPSValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([DPSValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: DPSValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported DPS value shape"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .number(let value):
            return value != 0
        case .string(let value):
            let lowered = value.lowercased()
            if ["true", "on", "open", "1", "yes"].contains(lowered) { return true }
            if ["false", "off", "close", "closed", "0", "no"].contains(lowered) { return false }
            return nil
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .bool(let value):
            return value ? 1 : 0
        case .string(let value):
            return Double(value.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    public var intValue: Int? {
        doubleValue.map { Int($0.rounded()) }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        default:
            return nil
        }
    }

    public var arrayValue: [DPSValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var description: String {
        switch self {
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return Self.format(value)
        case .string(let value):
            return value
        case .array(let values):
            return "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .object(let values):
            let body = values.keys.sorted().map { "\($0): \(values[$0]?.description ?? "")" }
            return "{" + body.joined(separator: ", ") + "}"
        case .null:
            return "null"
        }
    }

    public static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1_000_000 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

/// Read-only interpretation of one device's DPS map. All accessors are
/// optional; a missing or unexpected DP simply yields nil and the caller
/// renders a fallback.
public struct DeviceState {
    /// Tuya fs-category numeric gear fans support six custom speeds even though
    /// the cloud function spec does not expose dp 3's range. String-mode fans
    /// are the classic small/middle/large triple.
    public static let numericFanSpeedMax = 6
    public static let stringFanSpeedMax = 3
    public static let batteryNormalThreshold = 50.0
    public static let batteryLowThreshold = 20.0

    public let dps: [String: DPSValue]
    public let capabilities: [Capability]
    /// Cloud-code -> local-dp ids correlated by the bridge (status-only dps).
    public let codes: [String: String]

    public init(
        dps: [String: DPSValue],
        capabilities: [Capability] = [],
        codes: [String: String] = [:]
    ) {
        self.dps = dps
        self.capabilities = capabilities
        self.codes = codes
    }

    /// Percent only for v1: battery level enums (1-4) are not rendered.
    public var batteryPercent: Double? {
        guard let dpId = codes["battery_percentage"] else { return nil }
        return dps[dpId]?.doubleValue
    }

    /// Controls rendered from the spec. dp 1 is the card's master power
    /// toggle, so it is not repeated here.
    public var controlCapabilities: [Capability] {
        capabilities.filter { $0.isInteractive && $0.dpId != "1" }
    }

    public func isDeclared(_ key: String?) -> Bool {
        guard let key = key else { return false }
        return capabilities.contains { $0.dpId == key }
    }

    public func value(_ key: String) -> DPSValue? {
        dps[key]
    }

    public var isEmpty: Bool { dps.isEmpty }

    public var power: Bool? { dps["1"]?.boolValue }

    // MARK: Fans

    public var fanSpeedKey: String? {
        // General rule: the fan speed key is the dps carrying a NUMERIC level
        // (search "2","3"); a string dps is a mode, not a level, and is only
        // used when no numeric speed dps exists. Study Fan's dps 2 "custom"
        // is one instance: it must lose to numeric dps 3.
        for key in ["2", "3"] {
            if dps[key]?.doubleValue != nil {
                return key
            }
        }
        for key in ["2", "3"] {
            if dps[key]?.stringValue != nil {
                return key
            }
        }
        return nil
    }

    public var fanSpeed: Int {
        // General rule: a speed control's range must equal the device's real
        // capability range — numeric-gear fans in the Tuya fs category support
        // 1-6; string-mode fans map small/middle/large to 1-3. Never a
        // UI-invented clamp.
        guard let key = fanSpeedKey, let value = dps[key] else { return 1 }
        if let number = value.doubleValue {
            return min(max(Int(number.rounded()), 1), fanSpeedMax)
        }
        switch value.stringValue?.lowercased() ?? "" {
        case "small": return 1
        case "middle", "medium": return 2
        case "large": return 3
        default: return 1
        }
    }

    public var fanSpeedMax: Int {
        guard let key = fanSpeedKey else { return Self.numericFanSpeedMax }
        return dps[key]?.doubleValue != nil ? Self.numericFanSpeedMax : Self.stringFanSpeedMax
    }

    /// General rule: a numeric gear-speed dp is settable locally but is often
    /// absent from a cloud-fallback status reply (the cloud spec hides dp 3 on
    /// custom-mode fans). Callers use this to explain the missing control
    /// instead of silently rendering nothing.
    public var hasNumericFanSpeed: Bool {
        guard let key = fanSpeedKey else { return false }
        return dps[key]?.doubleValue != nil
    }

    public var oscillationKey: String? {
        for key in ["5", "4"] where dps[key]?.boolValue != nil {
            return key
        }
        return nil
    }

    public var oscillation: Bool {
        guard let key = oscillationKey else { return false }
        return dps[key]?.boolValue ?? false
    }

    // MARK: Curtains

    public var position: Double? {
        guard let key = curtainPositionKey, let value = dps[key]?.doubleValue else { return nil }
        return min(max(value, 0), 100)
    }

    // General rule: in a curtain's dps pair, the STRING-valued dp carries
    // actions (open/stop/close) and the NUMERIC-valued dp carries position
    // percent — select each key by value type (mirroring fan speed), never by
    // fixed key number. Fallback to fixed keys only when types are ambiguous.
    public var curtainActionKey: String? {
        for key in ["1", "2", "3"] where dps[key]?.stringValue != nil {
            return key
        }
        return nil
    }

    public var curtainPositionKey: String? {
        for key in ["2", "3"] where dps[key]?.doubleValue != nil {
            return key
        }
        return nil
    }

    public var curtainAction: String? {
        guard let key = curtainActionKey else { return nil }
        return dps[key]?.stringValue
    }

    // MARK: Lights

    public var brightness: Double? {
        guard let value = dps["2"], let number = value.doubleValue, value.stringValue == nil else {
            return nil
        }
        return min(max(number, 10), 1000)
    }

    public var colorTempKey: String? {
        guard let value = dps["3"], value.doubleValue != nil else { return nil }
        return "3"
    }

    public var colorTemp: Double? {
        guard let value = dps["3"] else { return nil }
        return value.doubleValue
    }

    // MARK: Plugs

    public var watts: Double? {
        for key in ["19", "22"] {
            if let value = dps[key]?.doubleValue {
                return value > 100 ? value / 10 : value
            }
        }
        return nil
    }

    public var wattsText: String? {
        guard let watts = watts else { return nil }
        return "⚡ \(DPSValue.format(watts)) W"
    }

    public var current: Double? {
        guard let value = dps["18"]?.doubleValue else { return nil }
        return value > 100 ? value / 1000 : value
    }

    public var voltage: Double? {
        guard let value = dps["20"]?.doubleValue else { return nil }
        return value > 1000 ? value / 10 : value
    }

    // MARK: Climate

    public var temperature: Double? {
        for key in ["17", "1"] {
            if let value = dps[key]?.doubleValue, dps[key]?.stringValue == nil {
                return value > 100 ? value / 10 : value
            }
        }
        return nil
    }

    public var humidity: Double? {
        for key in ["18", "2"] {
            if let value = dps[key]?.doubleValue, dps[key]?.stringValue == nil {
                return min(max(value, 0), 100)
            }
        }
        return nil
    }

    // MARK: Detail rendering

    public struct Entry: Identifiable {
        public let key: String
        public let label: String
        public let value: String
        public var id: String { key }
    }

    public func entries(for kind: DeviceKind) -> [Entry] {
        sortedKeys.map { key in
            Entry(key: key, label: label(for: key, kind: kind), value: friendlyValue(for: key, kind: kind))
        }
    }

    private var sortedKeys: [String] {
        dps.keys.sorted { left, right in
            if let l = Int(left), let r = Int(right) { return l < r }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left < right
        }
    }

    private func label(for key: String, kind: DeviceKind) -> String {
        switch key {
        case "1":
            if kind == .climate && dps["17"] != nil { return "Power" }
            return kind == .climate ? "Temperature" : "Power"
        case "2":
            switch kind {
            case .fan: return "Fan speed"
            case .curtain: return "Position"
            case .light: return "Brightness"
            case .climate: return "Humidity"
            default: return "DP 2"
            }
        case "3":
            switch kind {
            case .curtain: return "Curtain action"
            case .light: return "Colour temperature"
            case .fan: return "Speed (alt)"
            default: return "DP 3"
            }
        case "4": return "Oscillation"
        case "5": return "Oscillation"
        case "17": return "Temperature"
        case "18": return kind == .climate ? "Humidity" : "Current"
        case "19": return "Power"
        case "20": return "Voltage"
        case "22": return "Power"
        default: return "DP \(key)"
        }
    }

    private func friendlyValue(for key: String, kind: DeviceKind) -> String {
        guard let value = dps[key] else { return "–" }

        if key == "1" {
            if kind == .climate && dps["17"] == nil, let temp = temperature {
                return "\(DPSValue.format(temp)) °C"
            }
            if let flag = value.boolValue { return flag ? "On" : "Off" }
        }

        switch key {
        case "2" where kind == .fan:
            if let speed = value.doubleValue { return "Level \(Int(speed.rounded()))" }
        case "2" where kind == .curtain:
            if let position = value.doubleValue { return "\(Int(position.rounded())) %" }
        case "2" where kind == .light:
            if let brightness = value.doubleValue { return "\(Int(brightness.rounded())) / 1000" }
        case "2" where kind == .climate:
            if let humidity = value.doubleValue { return "\(Int(humidity.rounded())) %" }
        case "3" where kind == .curtain:
            return value.stringValue?.capitalized ?? value.description
        case "4", "5":
            if let flag = value.boolValue { return flag ? "On" : "Off" }
        case "17":
            if let temp = value.doubleValue { return "\(DPSValue.format(temp > 100 ? temp / 10 : temp)) °C" }
        case "18" where kind == .climate:
            if let humidity = value.doubleValue { return "\(Int(humidity.rounded())) %" }
        case "18":
            if let current = value.doubleValue {
                return String(format: "%.2f A", current > 100 ? current / 1000 : current)
            }
        case "19", "22":
            if let watts = value.doubleValue {
                return "\(DPSValue.format(watts > 100 ? watts / 10 : watts)) W"
            }
        case "20":
            if let volts = value.doubleValue {
                return "\(DPSValue.format(volts > 1000 ? volts / 10 : volts)) V"
            }
        default:
            break
        }
        return value.description
    }
}

// Unified device-control API — capability mapping.
//
// General rule: A SEMANTIC COMMAND IS ONLY OFFERED WHEN THE DEVICE CAN DO IT,
// and when it is, the write is exactly the one the dashboard performs for the
// same gesture (same dp key, same value scale). Dp selection therefore reuses
// DeviceState's status-driven heuristics (fanSpeedKey, curtainActionKey …) and
// the spec's declared ranges; nothing here invents a dp number.
import Foundation

/// Snapshot of what the map needs to know about one device.
public struct DeviceProfile {
    public let device: Device
    public let state: DeviceState
    public let isBriturn: Bool

    public init(device: Device, state: DeviceState, isBriturn: Bool) {
        self.device = device
        self.state = state
        self.isBriturn = isBriturn
    }

    public var kind: DeviceKind { device.kind }
}

public enum CapabilityMap {
    /// The concrete write for a command on a device.
    public enum WritePlan: Equatable {
        /// `DeviceStore.setDps(device, [dpId: raw], optimistic: [dpId: value])`.
        case tuya(dpId: String, value: DPSValue)
        /// `DeviceStore.setBriturn` / `setBriturnGroupState` arguments.
        case briturn(on: Bool?, color: RGB?, brightness: Int?, cct: Int?)
    }

    /// What the store's published state must show for the write to count as
    /// verified. `.accepted` means the store's own transport result is the
    /// only evidence (Briturn colour/brightness readback is channel-scaled
    /// and defended by the store's intent window, so it is not re-derived).
    public enum Expectation: Equatable {
        case dps(dpId: String, value: DPSValue)
        case briturnPower(Bool)
        case accepted
    }

    public enum Rejection: Equatable, Error {
        case unsupported(SemanticCapability)
        case needsStatus(SemanticCapability)
        case outOfRange(SemanticCapability, lower: Int, upper: Int)
        case unknownMode(String, options: [String])
    }

    /// Tuya dp vocabulary: cloud function codes (spec) and the status-driven
    /// fallbacks DeviceState already uses. Protocol constants, not settings.
    public enum Tuya {
        public static let powerDp = "1"
        public static let powerCodePrefix = "switch"
        public static let brightnessCodePrefix = "bright_value"
        public static let brightnessFallbackDp = "2"
        public static let brightnessFallbackRange = 10.0...1000.0
        public static let colorTempCodePrefix = "temp_value"
        public static let colorTempFallbackRange = 0.0...1000.0
        public static let fanSpeedCodePrefixes = ["fan_speed", "speed"]
        public static let fanGearRange = 1.0...Double(DeviceState.numericFanSpeedMax)
        public static let stringGears = ["small", "middle", "large"]
        public static let curtainPositionCodePrefix = "percent_control"
        public static let curtainPositionRange = 0.0...100.0
        public static let coverCodePrefix = "control"
        public static let modeCodes = ["work_mode", "mode"]
    }

    /// Briturn bulbs take brightness and CCT as 0…100 (bridge contract).
    public enum Briturn {
        public static let percentRange = Percent.range
    }

    // MARK: - Supported capabilities

    public static func supported(for profile: DeviceProfile) -> Set<SemanticCapability> {
        if profile.isBriturn {
            return [.power, .level, .color, .colorTemperature]
        }
        var result = Set<SemanticCapability>()
        if powerDp(profile) != nil { result.insert(.power) }
        if levelTarget(profile) != nil || (profile.kind == .fan && fanSpeedTarget(profile) != nil) { result.insert(.level) }
        if fanSpeedTarget(profile) != nil { result.insert(.fanSpeed) }
        if colorTempTarget(profile) != nil { result.insert(.colorTemperature) }
        if !enumCapabilities(profile).isEmpty { result.insert(.mode) }
        if coverTarget(profile) != nil { result.insert(.openClose) }
        return result
    }

    public static func supports(_ command: DeviceCommand, profile: DeviceProfile) -> Bool {
        if case .success = plan(command, for: profile) { return true }
        return false
    }

    // MARK: - Planning

    public static func plan(_ command: DeviceCommand, for profile: DeviceProfile) -> Result<WritePlan, Rejection> {
        if profile.isBriturn { return briturnPlan(command) }
        switch command {
        case .power(let on):
            guard let dp = powerDp(profile) else { return .failure(.unsupported(.power)) }
            return .success(.tuya(dpId: dp, value: .bool(on)))

        case .level(let percent):
            guard Percent.range.contains(percent) else {
                return .failure(.outOfRange(.level, lower: Percent.range.lowerBound, upper: Percent.range.upperBound))
            }
            if profile.kind == .fan {
                // "50%" on a fan is a gear: the nearest fraction of the top
                // gear (3 of 6), never below the lowest gear.
                guard let target = fanSpeedTarget(profile) else { return .failure(.needsStatus(.fanSpeed)) }
                let fraction = Double(Percent.clamp(percent)) / Double(Percent.range.upperBound)
                let gear = Int((fraction * target.range.upperBound).rounded())
                return fanSpeedPlan(min(max(gear, Int(target.range.lowerBound)), Int(target.range.upperBound)), target: target)
            }
            guard let target = levelTarget(profile) else { return .failure(.unsupported(.level)) }
            let raw = Percent.scaled(percent, to: target.range.lowerBound, target.range.upperBound, step: target.step)
            return .success(.tuya(dpId: target.dpId, value: .number(Double(raw))))

        case .fanSpeed(let gear):
            guard profile.kind == .fan || fanSpeedTarget(profile) != nil else { return .failure(.unsupported(.fanSpeed)) }
            guard let target = fanSpeedTarget(profile) else { return .failure(.needsStatus(.fanSpeed)) }
            return fanSpeedPlan(gear, target: target)

        case .colorTemperature(let percent):
            guard Percent.range.contains(percent) else {
                return .failure(.outOfRange(.colorTemperature, lower: Percent.range.lowerBound, upper: Percent.range.upperBound))
            }
            guard let target = colorTempTarget(profile) else { return .failure(.unsupported(.colorTemperature)) }
            let raw = Percent.scaled(percent, to: target.range.lowerBound, target.range.upperBound, step: target.step)
            return .success(.tuya(dpId: target.dpId, value: .number(Double(raw))))

        case .mode(let value):
            return modePlan(value, profile: profile)

        case .cover(let action):
            guard let target = coverTarget(profile) else { return .failure(.unsupported(.openClose)) }
            if !target.options.isEmpty, !target.options.contains(where: { $0.caseInsensitiveCompare(action.rawValue) == .orderedSame }) {
                return .failure(.unknownMode(action.rawValue, options: target.options))
            }
            return .success(.tuya(dpId: target.dpId, value: .string(action.rawValue)))

        case .color:
            // Tuya colour_data is a vendor-specific HSV encoding the dashboard
            // never writes; colour stays Briturn-only until a verified encoder
            // exists.
            return .failure(.unsupported(.color))
        }
    }

    /// The published-state condition that proves a plan landed.
    public static func expectation(for plan: WritePlan) -> Expectation {
        switch plan {
        case .tuya(let dpId, let value):
            return .dps(dpId: dpId, value: value)
        case .briturn(let on, let color, let brightness, let cct):
            if let on = on, color == nil, brightness == nil, cct == nil { return .briturnPower(on) }
            return .accepted
        }
    }

    // MARK: - Briturn

    private static func briturnPlan(_ command: DeviceCommand) -> Result<WritePlan, Rejection> {
        switch command {
        case .power(let on):
            return .success(.briturn(on: on, color: nil, brightness: nil, cct: nil))
        case .level(let percent):
            guard Briturn.percentRange.contains(percent) else {
                return .failure(.outOfRange(.level, lower: Briturn.percentRange.lowerBound, upper: Briturn.percentRange.upperBound))
            }
            return .success(.briturn(on: nil, color: nil, brightness: percent, cct: nil))
        case .color(let rgb):
            return .success(.briturn(on: nil, color: rgb, brightness: nil, cct: nil))
        case .colorTemperature(let percent):
            guard Briturn.percentRange.contains(percent) else {
                return .failure(.outOfRange(.colorTemperature, lower: Briturn.percentRange.lowerBound, upper: Briturn.percentRange.upperBound))
            }
            return .success(.briturn(on: nil, color: nil, brightness: nil, cct: percent))
        case .mode:
            return .failure(.unsupported(.mode))
        case .fanSpeed:
            return .failure(.unsupported(.fanSpeed))
        case .cover:
            return .failure(.unsupported(.openClose))
        }
    }

    // MARK: - Tuya dp targets

    struct NumericTarget: Equatable {
        let dpId: String
        let range: ClosedRange<Double>
        let step: Double?
        /// Non-empty for enum gears (string fans).
        let options: [String]
    }

    private static func capability(_ profile: DeviceProfile, dpId: String) -> Capability? {
        profile.state.capabilities.first { $0.dpId == dpId }
    }

    private static func capability(_ profile: DeviceProfile, codePrefix: String, kind: CapabilityKind) -> Capability? {
        profile.state.capabilities.first { $0.kind == kind && $0.code.lowercased().hasPrefix(codePrefix) }
    }

    private static func declaredRange(_ capability: Capability, fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let lower = capability.minValue, let upper = capability.maxValue, upper >= lower else { return fallback }
        return lower...upper
    }

    static func powerDp(_ profile: DeviceProfile) -> String? {
        let capabilities = profile.state.capabilities
        if !capabilities.isEmpty {
            if let dp1 = capability(profile, dpId: Tuya.powerDp), dp1.kind == .boolean { return Tuya.powerDp }
            // dp 1 is absent or something else (a curtain action enum, a
            // sensor reading): only a declared switch_* boolean is power.
            if let declared = capabilities.first(where: { $0.kind == .boolean && $0.code.lowercased().hasPrefix(Tuya.powerCodePrefix) }) {
                return declared.dpId
            }
            if capability(profile, dpId: Tuya.powerDp) != nil { return nil }
        }
        if let live = profile.state.dps[Tuya.powerDp] { return live.boolValue == nil ? nil : Tuya.powerDp }
        if profile.kind == .curtain { return nil }
        return Tuya.powerDp
    }

    static func levelTarget(_ profile: DeviceProfile) -> NumericTarget? {
        switch profile.kind {
        case .light:
            if let declared = capability(profile, codePrefix: Tuya.brightnessCodePrefix, kind: .integer) {
                return NumericTarget(dpId: declared.dpId, range: declaredRange(declared, fallback: Tuya.brightnessFallbackRange), step: declared.step, options: [])
            }
            if let dp2 = capability(profile, dpId: Tuya.brightnessFallbackDp), dp2.kind != .integer { return nil }
            return NumericTarget(dpId: Tuya.brightnessFallbackDp, range: Tuya.brightnessFallbackRange, step: nil, options: [])
        case .curtain:
            if let key = profile.state.curtainPositionKey {
                let declared = capability(profile, dpId: key)
                let range = declared.map { declaredRange($0, fallback: Tuya.curtainPositionRange) } ?? Tuya.curtainPositionRange
                return NumericTarget(dpId: key, range: range, step: declared?.step, options: [])
            }
            if let declared = capability(profile, codePrefix: Tuya.curtainPositionCodePrefix, kind: .integer) {
                return NumericTarget(dpId: declared.dpId, range: declaredRange(declared, fallback: Tuya.curtainPositionRange), step: declared.step, options: [])
            }
            return nil
        default:
            return nil
        }
    }

    static func fanSpeedTarget(_ profile: DeviceProfile) -> NumericTarget? {
        // DeviceState's dp 2/3 heuristic is only meaningful on a fan; any other
        // kind needs a declared fan_speed/speed code.
        let declaredByCode = Tuya.fanSpeedCodePrefixes.lazy.compactMap { prefix -> Capability? in
            capability(profile, codePrefix: prefix, kind: .integer) ?? capability(profile, codePrefix: prefix, kind: .enumeration)
        }.first
        guard profile.kind == .fan || declaredByCode != nil else { return nil }
        let state = profile.state
        if profile.kind == .fan, let key = state.fanSpeedKey {
            let declared = capability(profile, dpId: key)
            if state.hasNumericFanSpeed {
                let range = declared.map { declaredRange($0, fallback: Tuya.fanGearRange) } ?? Tuya.fanGearRange
                return NumericTarget(dpId: key, range: range, step: declared?.step, options: [])
            }
            let options = declared.flatMap { $0.range.isEmpty ? nil : $0.range } ?? Tuya.stringGears
            return NumericTarget(dpId: key, range: 1.0...Double(options.count), step: 1, options: options)
        }
        guard let declared = declaredByCode else { return nil }
        if declared.kind == .integer {
            return NumericTarget(dpId: declared.dpId, range: declaredRange(declared, fallback: Tuya.fanGearRange), step: declared.step, options: [])
        }
        guard !declared.range.isEmpty else { return nil }
        return NumericTarget(dpId: declared.dpId, range: 1.0...Double(declared.range.count), step: 1, options: declared.range)
    }

    private static func fanSpeedPlan(_ gear: Int, target: NumericTarget) -> Result<WritePlan, Rejection> {
        let lower = Int(target.range.lowerBound)
        let upper = Int(target.range.upperBound)
        guard gear >= lower, gear <= upper else {
            return .failure(.outOfRange(.fanSpeed, lower: lower, upper: upper))
        }
        if target.options.isEmpty {
            return .success(.tuya(dpId: target.dpId, value: .number(Double(gear))))
        }
        return .success(.tuya(dpId: target.dpId, value: .string(target.options[gear - 1])))
    }

    static func colorTempTarget(_ profile: DeviceProfile) -> NumericTarget? {
        guard profile.kind == .light else { return nil }
        if let declared = capability(profile, codePrefix: Tuya.colorTempCodePrefix, kind: .integer) {
            return NumericTarget(dpId: declared.dpId, range: declaredRange(declared, fallback: Tuya.colorTempFallbackRange), step: declared.step, options: [])
        }
        if let key = profile.state.colorTempKey {
            return NumericTarget(dpId: key, range: Tuya.colorTempFallbackRange, step: nil, options: [])
        }
        return nil
    }

    static func enumCapabilities(_ profile: DeviceProfile) -> [Capability] {
        profile.state.capabilities.filter { $0.kind == .enumeration && !$0.range.isEmpty }
    }

    private static func modePlan(_ value: String, profile: DeviceProfile) -> Result<WritePlan, Rejection> {
        let enums = enumCapabilities(profile)
        guard !enums.isEmpty else { return .failure(.unsupported(.mode)) }
        let matches = enums.compactMap { capability -> (Capability, String)? in
            guard let option = capability.range.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return nil }
            return (capability, option)
        }
        let allOptions = Array(Set(enums.flatMap(\.range))).sorted()
        switch matches.count {
        case 0:
            return .failure(.unknownMode(value, options: allOptions))
        case 1:
            return .success(.tuya(dpId: matches[0].0.dpId, value: .string(matches[0].1)))
        default:
            // Several enum dps accept this word: prefer the conventional mode
            // codes, otherwise refuse rather than guess.
            if let preferred = matches.first(where: { pair in Tuya.modeCodes.contains(pair.0.code.lowercased()) }) {
                return .success(.tuya(dpId: preferred.0.dpId, value: .string(preferred.1)))
            }
            return .failure(.unknownMode(value, options: allOptions))
        }
    }

    struct CoverTarget: Equatable {
        let dpId: String
        let options: [String]
    }

    static func coverTarget(_ profile: DeviceProfile) -> CoverTarget? {
        guard profile.kind == .curtain else { return nil }
        if let key = profile.state.curtainActionKey {
            return CoverTarget(dpId: key, options: capability(profile, dpId: key)?.range ?? [])
        }
        if let declared = capability(profile, codePrefix: Tuya.coverCodePrefix, kind: .enumeration) {
            return CoverTarget(dpId: declared.dpId, options: declared.range)
        }
        return nil
    }

    // MARK: - Readback helpers

    /// Current level as a percent, for summaries and the model's context.
    public static func levelPercent(_ profile: DeviceProfile, briturn: DeviceStore.BriturnState?) -> Int? {
        if profile.isBriturn {
            guard let state = briturn else { return nil }
            let peak = Double(max(state.r, state.g, state.b, state.whiteLevel))
            return Percent.unscaled(peak, from: 0, 255)
        }
        if profile.kind == .fan, let target = fanSpeedTarget(profile), profile.state.fanSpeedKey != nil {
            // Inverse of the level→gear rule above: gear 3 of 6 reads 50%.
            return Percent.unscaled(Double(profile.state.fanSpeed), from: 0, target.range.upperBound)
        }
        guard let target = levelTarget(profile), let raw = profile.state.dps[target.dpId]?.doubleValue else { return nil }
        return Percent.unscaled(raw, from: target.range.lowerBound, target.range.upperBound)
    }
}

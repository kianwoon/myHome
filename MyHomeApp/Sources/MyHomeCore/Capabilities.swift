// baseline-guard:allow new capability layer source, no prior baseline
import Foundation

/// General rule: CONTROLS ARE DERIVED FROM UPSTREAM CAPABILITY METADATA (the
/// Tuya cloud specification). Each declared Boolean dp renders a toggle, each
/// Enum dp renders a picker over its declared range, and each Integer dp with
/// a declared range renders a slider using those bounds. Inferred dps shapes
/// are a FALLBACK only for dps the spec does not declare (e.g. the Study
/// Fan's gear dp 3).
public struct DPDeclaration: Decodable, Hashable {
    public let code: String
    public let type: String
    public let values: [String: DPSValue]

    private enum CodingKeys: String, CodingKey {
        case code, type, values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? container.decode(String.self, forKey: .code)) ?? ""
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        if let decoded = try? container.decode([String: DPSValue].self, forKey: .values) {
            values = decoded
        } else {
            values = [:]
        }
    }
}

public enum CapabilityKind {
    case boolean
    case enumeration
    case integer
    case other
}

public struct Capability: Identifiable, Hashable {
    public let dpId: String
    public let code: String
    public let type: String
    public let range: [String]
    public let minValue: Double?
    public let maxValue: Double?
    public let step: Double?
    public let unit: String?

    public var id: String { dpId }

    public init(dpId: String, declaration: DPDeclaration) {
        self.dpId = dpId
        code = declaration.code
        type = declaration.type

        let values = declaration.values
        range = (values["range"]?.arrayValue ?? []).compactMap { value in
            value.stringValue ?? value.description
        }
        minValue = values["min"]?.doubleValue
        maxValue = values["max"]?.doubleValue
        step = values["step"]?.doubleValue
        unit = values["unit"]?.stringValue
    }

    public var kind: CapabilityKind {
        switch type.lowercased() {
        case "boolean": return .boolean
        case "enum": return .enumeration
        case "integer", "value": return .integer
        default: return .other
        }
    }

    public var isInteractive: Bool {
        switch kind {
        case .boolean:
            return true
        case .enumeration:
            return !range.isEmpty
        case .integer:
            return minValue != nil && maxValue != nil
        case .other:
            return false
        }
    }

    public var displayName: String {
        guard !code.isEmpty else { return "DP \(dpId)" }
        let spaced = code.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return spaced }
        return String(first).uppercased() + spaced.dropFirst()
    }
}

public extension Device {
    var capabilities: [Capability] {
        (spec ?? [:]).map { Capability(dpId: $0.key, declaration: $0.value) }
            .sorted { left, right in
                if let l = Int(left.dpId), let r = Int(right.dpId) { return l < r }
                return left.dpId < right.dpId
            }
    }
}

public extension Capability {
    /// Human-readable reading of a reported value, driven by this dp's own
    /// declaration (type + unit) rather than a per-index guess.
    func formatted(_ value: DPSValue) -> String {
        switch kind {
        case .boolean:
            if let flag = value.boolValue { return flag ? "On" : "Off" }
        case .integer:
            if let number = value.doubleValue {
                let text = DPSValue.format(number)
                guard let unit, !unit.isEmpty else { return text }
                return "\(text) \(unit)"
            }
        case .enumeration, .other:
            break
        }
        return value.stringValue ?? value.description
    }
}

// baseline-guard:allow new source file, no prior baseline
import Foundation

public struct Device: Identifiable, Decodable, Hashable {
    public let id: String
    public let name: String
    public let ip: String
    public let version: String?
    public let category: String
    public let group: String?
    /// Tuya device location. Independent of `group`, which is Briturn-only.
    public let room: String
    public let online: Bool
    public let spec: [String: DPDeclaration]?
    public let codes: [String: String]?

    public var hasAddress: Bool { !ip.isEmpty }

    public init(
        id: String,
        name: String,
        ip: String,
        version: String?,
        category: String,
        group: String? = nil,
        online: Bool,
        spec: [String: DPDeclaration]? = nil,
        codes: [String: String]? = nil,
        room: String = ""
    ) {
        self.id = id
        self.name = name
        self.ip = ip
        self.version = version
        self.category = category
        self.group = group
        self.room = room
        self.online = online
        self.spec = spec
        self.codes = codes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, ip, version, category, group, room, online, spec, codes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Device"
        ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        group = try container.decodeIfPresent(String.self, forKey: .group)
        room = try container.decodeIfPresent(String.self, forKey: .room) ?? ""
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        spec = try container.decodeIfPresent([String: DPDeclaration].self, forKey: .spec)
        codes = try container.decodeIfPresent([String: String].self, forKey: .codes)

        if let string = try? container.decodeIfPresent(String.self, forKey: .version) {
            version = string
        } else if let number = try? container.decodeIfPresent(Double.self, forKey: .version) {
            version = String(format: "%g", number)
        } else {
            version = nil
        }
    }
}

/// Icon and grouping decision for a device, driven by category first and
/// name keywords as the fallback.
public enum DeviceKind: String, Equatable, Codable, Sendable {
    case fan, curtain, light, plug, climate, purifier, kettle, speaker, unknown

    public var iconName: String {
        switch self {
        case .fan: return "fanblades.fill"
        case .curtain: return "curtains.closed"
        case .light: return "lightbulb.fill"
        case .plug: return "powerplug.fill"
        case .climate: return "thermometer.medium"
        case .purifier: return "aqi.medium"
        case .kettle: return "cup.and.saucer.fill"
        case .speaker: return "speaker.wave.2.fill"
        case .unknown: return "dot.radiowaves.left.and.right"
        }
    }

    public var label: String {
        switch self {
        case .fan: return "Fan"
        case .curtain: return "Curtain"
        case .light: return "Light"
        case .plug: return "Power"
        case .climate: return "Climate"
        case .purifier: return "Purifier"
        case .kettle: return "Kitchen"
        case .speaker: return "Speaker"
        case .unknown: return "Device"
        }
    }

    public static func classify(category: String, name: String) -> DeviceKind {
        switch category.lowercased() {
        case "cl":
            return .curtain
        case "kef":
            return .speaker
        case "dj", "xdd", "briturn":
            return .light
        case "fs", "fsd":
            return .fan
        case "wsdcg", "cq":
            return .climate
        case "cz", "kg":
            return .plug
        default:
            break
        }

        let lowered = name.lowercased()
        if lowered.contains("curtain") { return .curtain }
        if lowered.contains("fan") { return .fan }
        if lowered.contains("light") || lowered.contains("lamp") { return .light }
        if lowered.contains("purifier") || lowered.contains("filter") { return .purifier }
        if lowered.contains("humidity") || lowered.contains("climate") || lowered.contains("thermostat") { return .climate }
        if lowered.contains("heater") || lowered.contains("cooker") || lowered.contains("rice") { return .kettle }
        if lowered.contains("water") || lowered.contains("computer") || lowered.contains("internet")
            || lowered.contains("power") || lowered.contains("plug") {
            return .plug
        }
        return .unknown
    }
}

extension Device {
    /// BLE-transport lights live only on the app side (discovered over
    /// CoreBluetooth); they have no WiFi address and no bridge roster entry.
    public var isBLE: Bool { id.hasPrefix("ble-") }

    public var kind: DeviceKind {
        DeviceKind.classify(category: category, name: name)
    }
}

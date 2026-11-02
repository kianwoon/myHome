import Foundation

public struct BriturnCloudDevice: Codable, Equatable {
    public let deviceID: Int
    public let homeID: Int
    public let entityType: String
    public let macAddress: String
    public let name: String
    public let productID: Int
    public let online: Bool
    public let functions: Set<String>
    /// Cloud group name (from the group/relation endpoints); nil when ungrouped or unknown.
    public var groupName: String?

    public var canonicalID: String {
        macAddress.isEmpty ? "briturn-cloud-\(entityType)-\(deviceID)" : "briturn-\(macAddress)"
    }
    public var supportsLighting: Bool { entityType == "TCP_WF" && productID == 95 }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    init(json: [String: Any], homeID: Int) throws {
        guard let id = Self.integer(json["deviceId"]), id > 0,
              let entity = json["entityType"] as? String, !entity.isEmpty,
              let product = Self.integer(json["productId"]) else { throw BriturnCloudError.invalidResponse }
        deviceID = id
        self.homeID = homeID
        entityType = entity
        let rawMAC = (json["macAddress"] as? String ?? "").lowercased().replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        macAddress = rawMAC.count == 12 && rawMAC.allSatisfy({ $0.isHexDigit && $0.isASCII }) ? rawMAC : ""
        name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Briturn Light"
        productID = product
        online = (json["entityData"] as? [String: Any])?["online"] as? Bool ?? false
        functions = Set((json["functionList"] as? [[String: Any]] ?? []).compactMap { $0["function"] as? String })
    }

    /// Exact MAC matches enrich local identities; cloud-only devices never inherit a stale cloud IP.
    public static func merge(local: [Device], cloud: [BriturnCloudDevice]) -> [Device] {
        let byID = Dictionary(cloud.map { ($0.canonicalID, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = local.map { device -> Device in
            guard device.category.lowercased() == "briturn", let item = byID[device.id] else { return device }
            return Device(id: device.id, name: item.name, ip: device.ip, version: device.version,
                          category: device.category, group: item.groupName ?? device.group, online: device.online,
                          spec: device.spec, codes: device.codes, room: device.room)
        }
        let localIDs = Set(local.map(\.id))
        for item in cloud where !localIDs.contains(item.canonicalID) {
            merged.append(Device(id: item.canonicalID, name: item.name, ip: "", version: "Cloud",
                                 category: "briturn", group: item.groupName, online: item.online))
        }
        return merged
    }
}

enum BriturnCloudPackets {
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func parseState(_ hex: String) -> DeviceStore.BriturnState? {
        guard hex.count % 2 == 0, hex.count <= 512, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        var position = hex.startIndex
        while position < hex.endIndex {
            let next = hex.index(position, offsetBy: 2)
            guard let byte = UInt8(hex[position..<next], radix: 16) else { return nil }
            bytes.append(byte)
            position = next
        }
        guard bytes.count == 14, bytes[0] == 0x81, bytes[1] == 0x5F,
              bytes[2] == 0x23 || bytes[2] == 0x24,
              bytes.dropLast().reduce(0, { $0 + Int($1) }) & 255 == Int(bytes.last!) else { return nil }
        return DeviceStore.BriturnState(on: bytes[2] == 0x23, rawPower: Int(bytes[2]),
                                       mode: Int(bytes[3]), r: Int(bytes[6]), g: Int(bytes[7]), b: Int(bytes[8]),
                                       w: Int(bytes[9]), cool: Int(bytes[11]), firmware: Int(bytes[10]))
    }

    private static func packet(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [UInt8(bytes.reduce(0, { $0 + Int($1) }) & 255)]
    }
    private static func percent(_ value: Int) -> UInt8 { UInt8(min(max(value, 0), 100)) }

    static func commands(state: DeviceStore.BriturnState, functions: Set<String>, on: Bool?,
                         color: (red: Int, green: Int, blue: Int)?, brightness: Int?, white: Bool, cct: Int?) throws -> [[UInt8]] {
        guard state.firmware >= 10,
              on == nil || functions.contains("POWER"),
              color == nil || functions.contains("RGB"),
              !(white || cct != nil) || functions.contains("CCT"),
              brightness == nil || functions.contains("RGB") || functions.contains("CCT") else {
            throw BriturnCloudError.unsupportedDevice
        }
        var result: [[UInt8]] = []
        if let on { result.append(packet([0x3B, on ? 0x23 : 0x24] + Array(repeating: 0, count: 10))) }
        if let color {
            let channels = [color.red, color.green, color.blue].map { Double(min(max($0, 0), 255)) / 255 }
            let high = channels.max()!, low = channels.min()!, delta = high - low
            var hue: Double = 0
            if delta > 0 {
                if high == channels[0] { hue = 60 * ((channels[1] - channels[2]) / delta).truncatingRemainder(dividingBy: 6) }
                else if high == channels[1] { hue = 60 * ((channels[2] - channels[0]) / delta + 2) }
                else { hue = 60 * ((channels[0] - channels[1]) / delta + 4) }
                if hue < 0 { hue += 360 }
            }
            let saturation = high == 0 ? 0 : delta / high
            result.append(packet([0x3B, 0xA1, UInt8(min(Int((hue / 2).rounded()), 180)),
                                  percent(Int((saturation * 100).rounded())),
                                  percent(Int((high * Double(percent(brightness ?? 100))).rounded())),
                                  0, 0, 0, 0, 0x1E, 0, 0]))
        }
        if white || cct != nil {
            let level = brightness ?? (state.whiteLevel > 0 ? max(1, Int((Double(state.whiteLevel) / 2.55).rounded())) : 100)
            result.append(packet([0x3B, 0xB1, 0, 0, 0, percent(cct ?? 0), percent(level), 0, 0, 0x1E, 0, 0]))
        } else if let brightness, color == nil {
            let level = percent(brightness)
            result.append(packet([0x3B, 1, 0, 0, level, 0, level, 0, 0, 0, 0, 0]))
        }
        return result
    }
}

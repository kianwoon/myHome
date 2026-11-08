// Cast speaker discovery over Bonjour (`_googlecast._tcp`) via SwiftCast.
// Every device is keyed by its stable TXT `id`, never by IP or port: a speaker
// group is advertised as an extra service and must not duplicate its leader.
import Foundation
import Network
import SwiftCast

public struct CastDiscoveredSpeaker: Equatable, Identifiable, Sendable {
    public let deviceID: String
    public let name: String
    public let model: String
    public let serviceName: String
    public let isGroup: Bool
    public let supportsVideo: Bool
    public var id: String { deviceID }

    public func record(room: String = "", name override: String? = nil) -> CastSpeakerRecord {
        CastSpeakerRecord(deviceID: deviceID, name: (override?.isEmpty == false ? override! : name),
                          room: room, model: model, serviceName: serviceName)
    }
}

public protocol CastServiceBrowsing: Sendable {
    func browse(timeout: TimeInterval) async -> [CastDiscoveredSpeaker]
}

public struct CastBonjourBrowser: CastServiceBrowsing {
    public init() {}

    public func browse(timeout: TimeInterval) async -> [CastDiscoveredSpeaker] {
        let devices = await SwiftCast.CastDiscovery.scan(for: .milliseconds(Int(timeout * 1000)))
        return devices.compactMap { device in
            guard case .service(let serviceName, _, _, _) = device.endpoint, !device.id.isEmpty else { return nil }
            return CastDiscoveredSpeaker(deviceID: device.id, name: device.name, model: device.modelName ?? "",
                                         serviceName: serviceName, isGroup: device.isGroup,
                                         supportsVideo: device.supportsVideo)
        }
    }
}

public enum CastSpeakerDiscovery {
    /// Audio-only devices first; displays/TVs are excluded (this is a speaker control).
    public static func discover(browser: CastServiceBrowsing = CastBonjourBrowser(),
                                timeout: TimeInterval = CastConfig.fromDefaults().discoveryTimeout) async -> [CastDiscoveredSpeaker] {
        var byID: [String: CastDiscoveredSpeaker] = [:]
        // KEF LS50 Wireless II also advertises Cast; the native KEF adapter owns it.
        for speaker in await browser.browse(timeout: timeout) where !speaker.supportsVideo && !KEFModel.isSupported(speaker.model) { byID[speaker.deviceID] = speaker }
        return byID.values.sorted { ($0.isGroup ? 1 : 0, $0.name) < ($1.isGroup ? 1 : 0, $1.name) }
    }
}

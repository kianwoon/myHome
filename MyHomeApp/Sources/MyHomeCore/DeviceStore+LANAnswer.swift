import Foundation

/// Direct-LAN answers vs. the slow-cycle cloud-connect flag. The cloud flag
/// refreshes only every few minutes and lags a device's recovery; a status
/// read straight off the LAN is current, first-hand proof the device is up.
extension DeviceStore {
    /// Any bridge `via` tag ("cloud", "appapi", ...) means the dps were NOT
    /// read from the device itself; only an untagged reply is a LAN read.
    public nonisolated static func isRemoteVia(_ via: Any?) -> Bool {
        guard let tag = via as? String else { return false }
        return !tag.isEmpty
    }

    /// True when the device's latest Tuya status came straight off the LAN and
    /// has not failed since. Briturn lights are excluded: their badge follows
    /// `reachability(for:)`, whose stale-LAN rule must stay authoritative.
    public func answeredOnLAN(_ device: Device) -> Bool {
        guard device.category.lowercased() != "briturn" else { return false }
        return statusViaCloud[device.id] == false && statusErrors[device.id] == nil
    }

    /// Badge rule: a direct LAN answer outranks a stale or pending cloud flag.
    public nonisolated static func badgeShowsLAN(cloud: Bool?, lanAnswered: Bool) -> Bool {
        lanAnswered && cloud != true
    }

    /// Badge text for a direct LAN answer, distinct from the cloud flag text.
    public nonisolated static let lanBadgeText = "⌂ online"
}

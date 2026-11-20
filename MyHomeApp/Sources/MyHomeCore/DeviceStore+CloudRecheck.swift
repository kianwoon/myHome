import Foundation

extension DeviceStore {
    /// True when any non-briturn device has a red cloud badge (`false`) and at
    /// least `interval` seconds passed since the last cloud-status refresh
    /// (nil lastRefresh counts as elapsed). Briturn entries are merged from the
    /// separate briturn cloud and never trigger a bridge `cloudstatus` re-fetch.
    nonisolated static func needsOfflineRecheck(cloudOnline: [String: Bool], briturnIDs: Set<String>,
                                    lastRefresh: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard cloudOnline.contains(where: { $0.value == false && !briturnIDs.contains($0.key) }) else { return false }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= interval
    }

    func needsOfflineRecheckNow() -> Bool {
        var briturnIDs = Set(briturnCloudDevices.keys)
        for device in bridgeRoster where device.category.lowercased() == "briturn" { briturnIDs.insert(device.id) }
        return Self.needsOfflineRecheck(cloudOnline: cloudOnline, briturnIDs: briturnIDs,
                                        lastRefresh: lastCloudStatusRefresh, now: Date(),
                                        interval: Self.cloudOfflineRecheckInterval)
    }
}

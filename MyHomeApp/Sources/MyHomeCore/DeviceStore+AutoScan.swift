import Foundation

/// Automatic periodic Briturn discovery, reusing `briturnScan()` (the bridge
/// command upserts by mac, so user names/rooms are kept and nothing is dropped).
extension DeviceStore {
    /// Delay before the first scan, after the launch refresh.
    public nonisolated static let autoScanInitialDelay: TimeInterval = 5
    /// How long a "new device" notice stays visible.
    public nonisolated static let newDeviceNoticeSeconds: TimeInterval = 20

    /// Devices present after a scan but not before, in roster order.
    public nonisolated static func newDevices(before: [Device], after: [Device]) -> [Device] {
        let known = Set(before.map(\.id))
        return after.filter { !known.contains($0.id) }
    }

    public nonisolated static func newDeviceNoticeText(_ added: [Device]) -> String? {
        guard let first = added.first else { return nil }
        if added.count == 1 { return "Found 1 new light: \(first.name)" }
        return "Found \(added.count) new lights: " + added.map(\.name).joined(separator: ", ")
    }

    /// One scan cycle. Skips when any refresh/rescan is running or a cycle is
    /// already in flight; returns whether a scan actually ran.
    @discardableResult
    public func autoScanOnce() async -> Bool {
        guard !isWorking, !isAutoScanning else { return false }
        isAutoScanning = true
        defer { isAutoScanning = false }
        let before = roster
        await briturnScan()
        if let text = Self.newDeviceNoticeText(Self.newDevices(before: before, after: roster)) {
            newDeviceNotice = text
            noticeTask?.cancel()
            noticeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.newDeviceNoticeSeconds * 1_000_000_000))
                if !Task.isCancelled { self?.newDeviceNotice = nil }
            }
        }
        return true
    }

    /// Runs until the calling task is cancelled (or the app quits). The
    /// interval is re-read every cycle; 0 = off, re-checked each minute so
    /// enabling it in Settings takes effect without a relaunch. Never faster
    /// than once a minute.
    public func runAutoScanLoop(defaults: UserDefaults = .standard) async {
        try? await Task.sleep(nanoseconds: UInt64(Self.autoScanInitialDelay * 1_000_000_000))
        var first = true
        while !Task.isCancelled {
            if first && AppSettings.autoScanMinutes(from: defaults) > 0 { await autoScanOnce() }
            first = false
            let wait = max(AppSettings.autoScanMinutes(from: defaults), 1)
            try? await Task.sleep(nanoseconds: UInt64(wait) * 60 * 1_000_000_000)
            if Task.isCancelled { break }
            if AppSettings.autoScanMinutes(from: defaults) > 0 { await autoScanOnce() }
        }
    }
}

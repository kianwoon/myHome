// Publish-rate meter: how often the store invalidates its observers.
//
// Every dashboard card observes the whole store, so each objectWillChange
// re-evaluates ~50 card bodies. This counts fires per window and attributes
// them per @Published property (each `$prop` emits on every assignment, in
// willSet), logging one line per window that saw any publish:
//   MyHome: store publishes=<n> in 10s top=<prop>:<n>,<prop>:<n>,...

import Combine
import Foundation

/// Plain counters, touched only on the main actor (the store's publishers
/// fire synchronously from main-actor setters).
final class PublishMeter {
    var total = 0
    var byProperty: [String: Int] = [:]
    var cancellables = Set<AnyCancellable>()

    func note(_ name: String) { byProperty[name, default: 0] += 1 }

    /// Returns and clears the window's counts.
    func drain() -> (total: Int, top: [(String, Int)]) {
        let result = (total, byProperty.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) })
        total = 0
        byProperty.removeAll(keepingCapacity: true)
        return result
    }
}

extension DeviceStore {
    /// Seconds per publish-meter log window.
    static let publishMeterWindow: TimeInterval = 10
    /// Properties named in the `top=` field of each window line.
    static let publishMeterTopCount = 6

    func startPublishMeter() {
        let meter = publishMeter
        objectWillChange.sink { _ in meter.total += 1 }.store(in: &meter.cancellables)
        func track<P: Publisher>(_ name: String, _ publisher: P) where P.Failure == Never {
            publisher.dropFirst().sink { _ in meter.note(name) }.store(in: &meter.cancellables)
        }
        track("roster", $roster)
        track("briturnCloudSyncing", $briturnCloudSyncing)
        track("briturnCloudError", $briturnCloudError)
        track("briturnCloudDeviceCount", $briturnCloudDeviceCount)
        track("bleLights", $bleLights)
        track("isOn", $isOn)
        track("dpsById", $dpsById)
        track("cloudOnline", $cloudOnline)
        track("cloudEnvBroken", $cloudEnvBroken)
        track("statusLoading", $statusLoading)
        track("statusErrors", $statusErrors)
        track("statusViaCloud", $statusViaCloud)
        track("schedules", $schedules)
        track("schedulesLoading", $schedulesLoading)
        track("schedulesError", $schedulesError)
        track("errorText", $errorText)
        track("isWorking", $isWorking)
        track("newDeviceNotice", $newDeviceNotice)
        track("bleGroups", $bleGroups)
        track("groupColours", $groupColours)
        track("briturnTimers", $briturnTimers)
        track("briturnTimersLoading", $briturnTimersLoading)
        track("briturnStatus", $briturnStatus)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.publishMeterWindow * 1_000_000_000))
                guard let self = self else { return }
                self.logPublishWindow()
            }
        }
    }

    func logPublishWindow() {
        let (total, ranked) = publishMeter.drain()
        guard total > 0 else { return }
        let top = ranked.prefix(Self.publishMeterTopCount).map { "\($0.0):\($0.1)" }.joined(separator: ",")
        AppLog.store.notice("MyHome: store publishes=\(total, privacy: .public) in \(Int(Self.publishMeterWindow), privacy: .public)s top=\(top, privacy: .public)")
    }
}

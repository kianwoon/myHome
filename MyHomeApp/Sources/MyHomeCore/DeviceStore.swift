// baseline-guard:allow rewrite of existing store for live polling and confirmed writes
import Foundation
import SwiftUI

/// Minimal seam over the stdio bridge so write paths can be unit-tested with a
/// canned `set` reply instead of real hardware.
public protocol BridgeSending: Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
}

extension BridgeClient: BridgeSending {}

public extension BridgeSending {
    /// Matches BridgeClient's default per-request timeout.
    func request(_ payload: [String: Any]) async throws -> [String: Any] {
        try await request(payload, timeout: 6)
    }
}

@MainActor
public final class DeviceStore: ObservableObject {
    /// General rule: device status is LIVE REMOTE data — it must be
    /// (a) re-polled periodically, (b) re-read after every write using the set
    /// reply's confirmed dps, and (c) never shown as authoritative without a
    /// fetch. One instance is the fan card: without polling it shows a stale
    /// speed after the wall switch or Tuya app changes it.
    ///
    /// One full cycle every 10s, round-robin, with a small pause between
    /// requests because the bridge is serial.
    public static let statusPollInterval: TimeInterval = 10
    public static let statusPollPacing: TimeInterval = 0.15

    /// General rule: device IDENTITY (names, roster membership) is
    /// cloud-authoritative and must re-sync on a schedule, just as STATUS is
    /// device-authoritative and re-syncs via polling. Status staleness was
    /// fixed by polling; identity staleness is fixed by periodic cloud sync.
    /// One full sync every 30 status cycles (~5 minutes).
    public static let cloudSyncInterval = 30

    /// General rule: LOCAL reachability and CLOUD connectivity are independent
    /// facts, so both are surfaced. Cloud status changes slowly — poll it on
    /// the same slow cycle as cloudsync, never on the 10s status cycle.
    public static let cloudStatusPollCycles = cloudSyncInterval

    @Published public private(set) var devices: [Device] = []
    @Published public private(set) var isOn: [String: Bool] = [:]
    @Published public private(set) var dpsById: [String: [String: DPSValue]] = [:]
    @Published public private(set) var cloudOnline: [String: Bool] = [:]
    /// True when the bridge itself cannot reach the Tuya cloud (e.g. it was
    /// launched with a python env missing `requests`). Distinct from per-device
    /// cloud offline: nothing cloud-backed (schedules, sync) can work until the
    /// app is relaunched so the bridge picks up the venv interpreter.
    @Published public private(set) var cloudEnvBroken = false
    @Published public private(set) var statusLoading: Set<String> = []
    @Published public private(set) var statusErrors: [String: String] = [:]
    @Published public private(set) var schedules: [DeviceSchedule] = []
    @Published public private(set) var schedulesLoading = false
    @Published public private(set) var schedulesError: String?
    @Published public private(set) var errorText: String?
    @Published public private(set) var isWorking = false

    /// Badge text for the independent cloud-connect fact; nil = not fetched.
    public nonisolated static func cloudBadgeText(_ online: Bool?) -> String {
        switch online {
        case .some(true): return "☁ online"
        case .some(false): return "☁ offline"
        case .none: return "☁ …"
        }
    }

    private let bridge: any BridgeSending
    /// Snapshot of the Control-tab defaults, read once on start so a poll cycle
    /// never changes cadence mid-flight.
    private let pollInterval: TimeInterval
    private let scanWindow: Int
    private var loadedStatus: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var pollObservers = 0
    private var cyclesSinceCloudSync = 0
    private var isCloudSyncing = false
    private var specsFetched = false
    private var specsFetching = false
    private var codesFetched = false
    private var codesFetching = false
    private var schedulesDeviceId: String?

    /// General rule: behavior-tuning values are user settings, not hard-coded
    /// constants. The constants below are the DEFAULTS; the Settings screen
    /// writes UserDefaults and this initializer snapshots them once.
    public init(bridge: any BridgeSending = BridgeClient.shared, defaults: UserDefaults = .standard) {
        self.bridge = bridge
        self.pollInterval = AppSettings.pollInterval(from: defaults)
        self.scanWindow = AppSettings.scanWindow(from: defaults)
    }

    // MARK: - Derived state

    public var onlineCount: Int {
        devices.filter { $0.online && $0.hasAddress }.count
    }

    public var onCount: Int {
        devices.filter {
            isOn[$0.id] == true || briturnStatus[$0.id]?.on == true
        }.count
    }

    public var headerText: String {
        "⚡ \(onCount) on · 🟢 \(onlineCount)/\(devices.count) online"
    }

    public func state(for device: Device) -> DeviceState {
        DeviceState(
            dps: dpsById[device.id] ?? [:],
            capabilities: device.capabilities,
            codes: device.codes ?? [:]
        )
    }

    /// nil until a fetch (or confirmed write) has reported dps 1.
    public func power(for device: Device) -> Bool? {
        isOn[device.id] ?? dpsById[device.id]?["1"]?.boolValue
    }

    public func dps(for device: Device) -> [String: DPSValue] {
        dpsById[device.id] ?? [:]
    }

    public func isLoadingStatus(_ device: Device) -> Bool {
        statusLoading.contains(device.id)
    }

    // MARK: - List / rescan

    public func refresh() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let reply = try await bridge.request(["cmd": "list"])
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Could not list devices."
                return
            }
            guard let rawDevices = reply["devices"] else {
                errorText = "Bridge returned no devices."
                return
            }
            let data = try JSONSerialization.data(withJSONObject: rawDevices)
            let decoded = try JSONDecoder().decode([Device].self, from: data)
            devices = decoded
            // Deliberately no isOn default: unknown power stays indeterminate
            // until status arrives.
            errorText = nil
            requestSpecsIfNeeded()
            requestCodeMapIfNeeded()
        } catch {
            errorText = error.localizedDescription
        }
    }

    public func rescan() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let reply = try await bridge.request(["cmd": "rescan", "window": scanWindow], timeout: 90)
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Scan failed."
                return
            }
            errorText = nil
            loadedStatus.removeAll()
            dpsById.removeAll()
            statusErrors.removeAll()
        } catch {
            errorText = error.localizedDescription
        }
        await refresh()
        // Manual Rescan also forces an immediate cloud identity sync.
        await cloudSync()
        // Status-only code correlations are refreshed with the roster.
        await refreshCodeMap()
    }

    /// A device-source scan owns its discovery command, but reuses the same
    /// working/reload contract as rescan: the sidebar refresh for a
    /// source-owned category calls this instead of the Tuya LAN rescan.
    public func briturnScan() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let reply = try await bridge.request(["cmd": "briturnscan"], timeout: 30)
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Briturn scan failed."
                return
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        await refresh()
    }

    // MARK: - Briturn (device-source controls)

    /// Wire-read state of one Zengge/Briturn light; mirrors the bridge's
    /// briturnstatus reply. rawPower is kept alongside the on-boolean so
    /// firmware variations stay diagnosable instead of silently mis-parsed.
    public struct BriturnState: Equatable {
        public let on: Bool
        public let rawPower: Int
        public let mode: Int
        public let r: Int
        public let g: Int
        public let b: Int
        public let w: Int

        init(on: Bool, rawPower: Int, mode: Int, r: Int, g: Int, b: Int, w: Int) {
            self.on = on
            self.rawPower = rawPower
            self.mode = mode
            self.r = r
            self.g = g
            self.b = b
            self.w = w
        }

        public var isWhiteMode: Bool {
            // The 2014 state frame reads rgb all-zero when the warm-white
            // element is active — physically lit, but rgb-black. Display and
            // picker logic must treat that as WHITE, not black.
            on && r == 0 && g == 0 && b == 0
        }

        init?(reply: [String: Any]) {
            guard let on = reply["on"] as? Bool,
                  let rawPower = reply["raw_power"] as? Int,
                  let mode = reply["mode"] as? Int,
                  let r = reply["r"] as? Int,
                  let g = reply["g"] as? Int,
                  let b = reply["b"] as? Int,
                  let w = reply["w"] as? Int
            else { return nil }
            self.on = on
            self.rawPower = rawPower
            self.mode = mode
            self.r = r
            self.g = g
            self.b = b
            self.w = w
        }
    }

    /// Latest wire-read state per briturn device id.
    @Published public private(set) var briturnStatus: [String: BriturnState] = [:]

    /// General rule: USER INTENT OUTRANKS A STALE WIRE READ. These bulbs apply
    /// power/colour with visible lag; a poll that lands mid-transition returns
    /// the OLD state and, if painted, visually bounces the user's toggle back.
    /// An intent records the last user command per device; wire reads that
    /// contradict a fresh intent are dropped (not painted), reads that agree
    /// confirm and clear it, and only the set command's own readback — taken
    /// after the bulb's settle delay — may overturn a fresh intent (the
    /// command was genuinely lost).
    private struct BriturnIntent {
        let on: Bool
        let at: Date
    }

    private var briturnIntent: [String: BriturnIntent] = [:]
    private static let briturnIntentGrace: TimeInterval = 8

    /// Paints a wire-read state unless it fights a fresh user intent.
    private func applyBriturnWireState(_ id: String, _ state: BriturnState, authoritative: Bool = false) {
        if let intent = briturnIntent[id],
           Date().timeIntervalSince(intent.at) < Self.briturnIntentGrace {
            if state.on == intent.on {
                // Device confirmed the user's instruction.
                briturnIntent.removeValue(forKey: id)
            } else if !authoritative {
                // Mid-transition poll: keep showing the user's instruction.
                return
            } else {
                // Authoritative readback says the command never took: the
                // device state is the truth, stop defending the intent.
                briturnIntent.removeValue(forKey: id)
            }
        }
        briturnStatus[id] = state
    }

    private func recordBriturnIntent(_ ids: [String], on: Bool) {
        let intent = BriturnIntent(on: on, at: Date())
        for id in ids {
            briturnIntent[id] = intent
        }
    }

    private func isBriturn(_ device: Device) -> Bool {
        device.category.lowercased() == "briturn"
    }

    public func loadBriturnStatus(for device: Device) async {
        guard isBriturn(device) else { return }
        guard device.hasAddress else {
            statusErrors[device.id] = "Briturn device has no IP yet — run a Briturn scan."
            return
        }
        do {
            let reply = try await bridge.request(["cmd": "briturnstatus", "id": device.id])
            guard reply["ok"] as? Bool == true else {
                statusErrors[device.id] = reply["error"] as? String ?? "Briturn status failed."
                return
            }
            guard let state = BriturnState(reply: reply) else {
                statusErrors[device.id] = "Unexpected briturn status reply."
                return
            }
            applyBriturnWireState(device.id, state)
            statusErrors[device.id] = nil
        } catch {
            statusErrors[device.id] = error.localizedDescription
        }
    }

    /// Sends power and/or colour and/or brightness, adopting the bridge's
    /// fresh readback as the new state — the device, not the request, is
    /// authoritative. Brightness (0-100) scales the peak colour channel; the
    /// base is the explicit colour when given, else the device's current one.
    public func setBriturn(
        _ device: Device,
        on: Bool? = nil,
        color: (red: Int, green: Int, blue: Int)? = nil,
        brightness: Int? = nil,
        white: Bool = false
    ) async {
        guard isBriturn(device) else { return }
        guard on != nil || color != nil || brightness != nil || white else { return }
        guard device.hasAddress else {
            statusErrors[device.id] = "Briturn device has no IP yet — run a Briturn scan."
            return
        }
        var payload: [String: Any] = ["cmd": "briturnset", "id": device.id]
        if let on = on { payload["on"] = on }
        if let color = color {
            payload["r"] = color.red
            payload["g"] = color.green
            payload["b"] = color.blue
        }
        if let brightness = brightness { payload["brightness"] = brightness }
        if white { payload["w"] = 128 }
        if let on = on {
            recordBriturnIntent([device.id], on: on)
        }
        // Optimistic paint from the request: without this the toggle binding
        // re-reads the stale cached state and visually snaps back ON until
        // the ~1s wire readback lands. The bridge's readback remains the
        // authority and overwrites this — a rejected set reverts on its own.
        let prev = briturnStatus[device.id]
        let nextOn = on ?? (prev?.on ?? false)
        let paintedWhite = white || (color == nil && (prev?.isWhiteMode ?? false) && brightness != nil)
        briturnStatus[device.id] = BriturnState(
            on: nextOn,
            rawPower: nextOn ? 0x23 : 0x24,
            mode: prev?.mode ?? 97,
            r: paintedWhite ? 0 : (color?.red ?? prev?.r ?? 255),
            g: paintedWhite ? 0 : (color?.green ?? prev?.g ?? 255),
            b: paintedWhite ? 0 : (color?.blue ?? prev?.b ?? 255),
            w: prev?.w ?? 0
        )
        do {
            let reply = try await bridge.request(payload, timeout: 30)
            guard reply["ok"] as? Bool == true else {
                statusErrors[device.id] = reply["error"] as? String ?? "Briturn set failed."
                briturnIntent.removeValue(forKey: device.id)
                briturnStatus[device.id] = prev
                return
            }
            statusErrors[device.id] = nil
            if let raw = reply["status"] as? [String: Any], let state = BriturnState(reply: raw) {
                applyBriturnWireState(device.id, state, authoritative: true)
            } else {
                // No usable readback (device dropped mid-command): re-query.
                await loadBriturnStatus(for: device)
            }
        } catch {
            statusErrors[device.id] = error.localizedDescription
            briturnIntent.removeValue(forKey: device.id)
            briturnStatus[device.id] = prev
        }
    }

    // MARK: - Briturn groups

    /// Sorted distinct group names across the briturn roster. Derived, never
    /// stored: a group with no members simply stops existing.
    public var briturnGroups: [String] {
        Array(Set(devices.compactMap { device -> String? in
            guard device.category.lowercased() == "briturn" else { return nil }
            guard let group = device.group, !group.isEmpty else { return nil }
            return group
        })).sorted()
    }

    public func members(of group: String) -> [Device] {
        devices.filter {
            $0.category.lowercased() == "briturn" && $0.group == group
        }
    }

    /// Assigns one device to a group (nil clears) and re-lists so the roster
    /// and every derived view update together.
    public func setBriturnGroup(_ device: Device, to group: String?) async {
        do {
            let reply = try await bridge.request([
                "cmd": "briturngroup",
                "id": device.id,
                "group": group ?? ""
            ], timeout: 10)
            guard reply["ok"] as? Bool == true else {
                statusErrors[device.id] = reply["error"] as? String ?? "Group assign failed."
                return
            }
            statusErrors[device.id] = nil
            await refresh()
        } catch {
            statusErrors[device.id] = error.localizedDescription
        }
    }

    /// Group-level power/colour. Optimistic paint per member (the same state
    /// the single-device path uses), then the bridge's applied-count reply is
    /// the authority; failed members fall back to their true state on the
    /// next poll cycle.
    public func setBriturnGroupState(
        _ group: String,
        on: Bool? = nil,
        color: (red: Int, green: Int, blue: Int)? = nil,
        brightness: Int? = nil
    ) async {
        guard on != nil || color != nil || brightness != nil else { return }
        let memberDevices = members(of: group)
        let memberIDs = memberDevices.filter(\.hasAddress).map(\.id)
        var payload: [String: Any] = ["cmd": "briturnsetgroup", "group": group]
        if let on = on { payload["on"] = on }
        if let color = color {
            payload["r"] = color.red
            payload["g"] = color.green
            payload["b"] = color.blue
        }
        if let brightness = brightness { payload["brightness"] = brightness }
        // Optimistic: paint EVERY member from the request plus its OWN prior
        // state — a member with no status yet must still show the group's new
        // state immediately, and a colour-only set must not clobber members'
        // individual power states. Brightness scales each member's own colour.
        var scale: Double = 1
        if let brightness = brightness, color == nil {
            scale = Double(brightness) * 2.55 / Double(
                max(briturnStatus[memberIDs.first ?? ""]?.r ?? 255,
                    briturnStatus[memberIDs.first ?? ""]?.g ?? 0,
                    briturnStatus[memberIDs.first ?? ""]?.b ?? 0, 1)
            )
        }
        for id in memberIDs {
            let prev = briturnStatus[id]
            let nextOn = on ?? (prev?.on ?? false)
            var r = color?.red ?? prev?.r ?? 255
            var g = color?.green ?? prev?.g ?? 255
            var b = color?.blue ?? prev?.b ?? 255
            if color == nil, brightness != nil {
                r = min(Int(Double(r) * scale), 255)
                g = min(Int(Double(g) * scale), 255)
                b = min(Int(Double(b) * scale), 255)
            }
            briturnStatus[id] = BriturnState(
                on: nextOn,
                rawPower: nextOn ? 0x23 : 0x24,
                mode: prev?.mode ?? 97,
                r: r, g: g, b: b,
                w: prev?.w ?? 0
            )
        }
        if let on = on {
            recordBriturnIntent(memberIDs, on: on)
        }
        do {
            let reply = try await bridge.request(payload, timeout: 30)
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Group set failed."
                return
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        // The poll cycle re-reads members and reconciles any failures, but a
        // full sweep takes seconds — reconcile just this group immediately.
        await refreshBriturnStatuses(limitingTo: members(of: group))
    }

    // MARK: - Polling

    /// Reference-counted so the menu extra and the main window can each keep
    /// polling alive independently.
    public func startPolling() {
        if ProcessInfo.processInfo.environment["MYHOME_NOPOLL"] == "1" { return }
        pollObservers += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self = self else { return }
            await self.pollLoop()
        }
    }

    public func stopPolling() {
        pollObservers = max(0, pollObservers - 1)
        guard pollObservers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop() async {
        let single = ProcessInfo.processInfo.environment["MYHOME_SINGLEPOLL"] == "1"
        while !Task.isCancelled {
            await pollCycle()
            if single { return }
            cyclesSinceCloudSync += 1
            if cyclesSinceCloudSync >= Self.cloudStatusPollCycles {
                cyclesSinceCloudSync = 0
                await cloudSync()
                await refreshCloudStatus()
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// Refreshes every briturn device's wire state once per poll cycle.
    /// Coalesced into one published write per cycle, mirroring the DPS batch.
    private func refreshBriturnStatuses(limitingTo devices: [Device]? = nil) async {
        let targets = (devices ?? self.devices)
            .filter { $0.hasAddress && !statusLoading.contains($0.id) }
            .filter { $0.category.lowercased() == "briturn" }
        var batch: [String: BriturnState] = [:]
        var errors: [String: String] = [:]
        for device in targets {
            if Task.isCancelled { break }
            statusLoading.insert(device.id)
            do {
                let reply = try await bridge.request(["cmd": "briturnstatus", "id": device.id])
                if reply["ok"] as? Bool == true, let state = BriturnState(reply: reply) {
                    batch[device.id] = state
                } else {
                    errors[device.id] = reply["error"] as? String ?? "Briturn status failed."
                }
            } catch {
                errors[device.id] = error.localizedDescription
            }
            statusLoading.remove(device.id)
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.statusPollPacing * 1_000_000_000))
            } catch {
                return
            }
        }
        if !batch.isEmpty {
            for (id, state) in batch {
                applyBriturnWireState(id, state)
            }
            var merged = statusErrors
            for id in batch.keys { merged[id] = nil }
            statusErrors = merged
        }
        if !errors.isEmpty {
            var merged = statusErrors
            for (id, message) in errors { merged[id] = message }
            statusErrors = merged
        }
    }

    /// Round-robin over online devices only; skip anything already in flight.
    ///
    /// General rule: a view must NEVER mutate observable state while it is
    /// being laid out. Polling therefore coalesces its results and writes each
    /// @Published collection ONCE per cycle instead of per device — per-device
    /// writes invalidate layout repeatedly and can feed a layout loop.
    private func pollCycle() async {
        // Briturn devices have no DPS surface; they are polled through their
        // own wire status so card toggles stay live.
        await refreshBriturnStatuses()
        let targets = devices
            .filter { $0.hasAddress && !statusLoading.contains($0.id) }
            .filter { $0.category.lowercased() != "briturn" }
            .map(\.id)
        guard !targets.isEmpty else { return }

        var dpsBatch: [String: [String: DPSValue]] = [:]
        var onBatch: [String: Bool] = [:]
        var errorBatch: [String: String] = [:]

        for id in targets {
            if Task.isCancelled { break }
            switch await fetchStatus(for: id) {
            case .success(let decoded):
                dpsBatch[id] = decoded
                if let power = decoded["1"]?.boolValue {
                    onBatch[id] = power
                }
            case .failure(let message):
                errorBatch[id] = message
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.statusPollPacing * 1_000_000_000))
            } catch {
                return
            }
        }

        applyPollBatch(dps: dpsBatch, on: onBatch, errors: errorBatch)
    }

    /// Single coalesced write for one poll cycle: each published collection is
    /// assigned once, so SwiftUI sees one invalidation rather than dozens.
    private func applyPollBatch(
        dps: [String: [String: DPSValue]],
        on: [String: Bool],
        errors: [String: String]
    ) {
        guard !dps.isEmpty || !errors.isEmpty else { return }
        if !dps.isEmpty {
            dpsById.merge(dps) { _, new in new }
            isOn.merge(on) { _, new in new }
            loadedStatus.formUnion(dps.keys)
        }
        var mergedErrors = statusErrors
        for id in dps.keys {
            mergedErrors[id] = nil
        }
        for (id, message) in errors {
            mergedErrors[id] = message
        }
        statusErrors = mergedErrors
    }

    // MARK: - Status

    /// Fetches DPS for one device. Non-forced calls are cached until a rescan
    /// or poll forces a re-read; concurrent calls for the same id de-duplicate.
    public func loadStatus(for device: Device, force: Bool = false) async {
        // Briturn devices have no Tuya DPS surface; their status comes from
        // loadBriturnStatus instead. Requesting Tuya status only produces
        // error noise.
        guard device.category.lowercased() != "briturn" else { return }
        guard device.hasAddress else { return }
        guard !statusLoading.contains(device.id) else { return }
        if !force && loadedStatus.contains(device.id) { return }

        statusLoading.insert(device.id)
        defer { statusLoading.remove(device.id) }

        switch await fetchStatus(for: device.id) {
        case .success(let decoded):
            applyStatus(device.id, decoded: decoded)
        case .failure(let message):
            statusErrors[device.id] = message
        }
    }

    private enum StatusFetch {
        case success([String: DPSValue])
        case failure(String)
    }

    private func fetchStatus(for id: String) async -> StatusFetch {
        do {
            let reply = try await bridge.request(["cmd": "status", "id": id])
            guard reply["ok"] as? Bool == true else {
                return .failure(reply["error"] as? String ?? "Status failed.")
            }
            guard let raw = reply["dps"] else {
                return .failure("Device returned no dps.")
            }
            return .success(try Self.decodeDps(raw))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Loads every briturn device's wire state once — launch-time parity with
    /// loadAllStatuses, so the on-count and chips are right immediately.
    public func loadAllBriturnStatuses() async {
        for device in devices where device.category.lowercased() == "briturn" {
            await loadBriturnStatus(for: device)
        }
    }

    public func loadAllStatuses() async {
        for device in devices where device.hasAddress {
            await loadStatus(for: device)
        }
    }

    /// Fetch upstream capability metadata once; the bridge caches per device.
    private func requestSpecsIfNeeded() {
        guard !specsFetched, !specsFetching else { return }
        guard devices.contains(where: { $0.spec == nil }) else {
            specsFetched = true
            return
        }
        specsFetching = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let reply = try await self.bridge.request(["cmd": "specs"], timeout: 60)
                if reply["ok"] as? Bool == true {
                    self.specsFetched = true
                    await self.refresh()
                }
            } catch {
                // Leave specsFetching false so a later refresh can retry.
            }
            self.specsFetching = false
        }
    }

    /// Correlates cloud status codes with local dps once per launch (the
    /// bridge caches the map in devices.json); rescan forces a refresh.
    private func requestCodeMapIfNeeded() {
        guard !codesFetching, !codesFetched else { return }
        guard devices.contains(where: { $0.codes == nil }) else {
            codesFetched = true
            return
        }
        codesFetching = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let reply = try await self.bridge.request(["cmd": "codemap"], timeout: 180)
                if reply["ok"] as? Bool == true {
                    self.codesFetched = true
                    await self.refresh()
                }
            } catch {
                // Leave codesFetching false so a later refresh can retry.
            }
            self.codesFetching = false
        }
    }

    /// Forced re-correlation used by manual Rescan.
    public func refreshCodeMap() async {
        do {
            let reply = try await bridge.request(["cmd": "codemap"], timeout: 180)
            if reply["ok"] as? Bool == true {
                codesFetched = true
                await refresh()
            }
        } catch {
            // Keep the previous map; the next rescan retries.
        }
    }

    /// Merges cloud-authoritative names/roster into devices.json (bridge side)
    /// and re-reads the roster so new/renamed devices appear immediately.
    public func cloudSync() async {
        guard !isCloudSyncing else { return }
        isCloudSyncing = true
        defer { isCloudSyncing = false }

        do {
            let reply = try await bridge.request(["cmd": "cloudsync"], timeout: 20)
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Cloud sync failed."
                return
            }
            errorText = nil
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Slow-cycle companion to cloudSync: refreshes the cloud connect map that
    /// the card and detail badges read. Failures leave prior values intact.
    public func refreshCloudStatus() async {
        do {
            let reply = try await bridge.request(["cmd": "cloudstatus"], timeout: 90)
            if reply["ok"] as? Bool == true {
                cloudEnvBroken = false
                guard let raw = reply["status"] else { return }
                let data = try JSONSerialization.data(withJSONObject: raw)
                cloudOnline = try JSONDecoder().decode([String: Bool].self, from: data)
            } else {
                // General rule: an env-level cloud failure is a distinct fact
                // from per-device offline; only a bridge-reported capability
                // flag flips it, so a transient cloud outage can't.
                cloudEnvBroken = (reply["cloud_capable"] as? Bool) == false
            }
        } catch {
            // Keep the last known cloud state; the badge stays neutral if none.
        }
    }

    /// Renames upstream (cloud-authoritative identity) and re-lists so the new
    /// name lands in the models. Returns false and leaves errorText set on
    /// failure; never logs credentials.
    @discardableResult
    public func rename(_ device: Device, to newName: String) async -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 50 else {
            errorText = "Name must be 1-50 characters."
            return false
        }
        do {
            let reply = try await bridge.request([
                "cmd": "rename",
                "id": device.id,
                "name": name
            ], timeout: 20)
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Rename failed."
                return false
            }
            errorText = nil
            await refresh()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    // MARK: - Schedules

    /// Schedules are cloud-owned (not part of the roster), so they are fetched
    /// on demand for the visible detail pane and reloaded after every change.
    public func loadSchedules(for device: Device) async {
        if schedulesDeviceId != device.id {
            schedulesDeviceId = device.id
            schedules = []
        }
        schedulesLoading = true
        defer { schedulesLoading = false }
        do {
            let reply = try await bridge.request(
                ["cmd": "schedules", "id": device.id],
                timeout: 20
            )
            guard reply["ok"] as? Bool == true else {
                schedulesError = reply["error"] as? String ?? "Could not load schedules."
                return
            }
            let raw = reply["schedules"] ?? []
            let data = try JSONSerialization.data(withJSONObject: raw)
            schedules = try JSONDecoder().decode([DeviceSchedule].self, from: data)
            schedulesError = nil
        } catch {
            schedulesError = error.localizedDescription
        }
    }

    @discardableResult
    public func addSchedule(
        for device: Device,
        name: String,
        days: [Bool],
        time: String,
        on: Bool
    ) async -> Bool {
        do {
            let reply = try await bridge.request([
                "cmd": "schedadd",
                "id": device.id,
                "name": name,
                "days": days.map { $0 ? 1 : 0 },
                "time": time,
                "on": on
            ], timeout: 20)
            guard reply["ok"] as? Bool == true else {
                schedulesError = reply["error"] as? String ?? "Could not add schedule."
                return false
            }
            schedulesError = nil
            await loadSchedules(for: device)
            return true
        } catch {
            schedulesError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func editSchedule(
        _ schedule: DeviceSchedule,
        for device: Device,
        name: String,
        days: [Bool],
        time: String,
        on: Bool
    ) async -> Bool {
        do {
            let reply = try await bridge.request([
                "cmd": "schededit",
                "id": device.id,
                "category": schedule.category,
                "group_id": schedule.groupId,
                "name": name,
                "days": days.map { $0 ? 1 : 0 },
                "time": time,
                "on": on
            ], timeout: 20)
            guard reply["ok"] as? Bool == true else {
                schedulesError = reply["error"] as? String ?? "Could not update schedule."
                return false
            }
            schedulesError = nil
            await loadSchedules(for: device)
            return true
        } catch {
            schedulesError = error.localizedDescription
            return false
        }
    }

    public func setScheduleEnabled(_ schedule: DeviceSchedule, for device: Device, enabled: Bool) async {
        do {
            let reply = try await bridge.request([
                "cmd": "schedtoggle",
                "id": device.id,
                "category": schedule.category,
                "group_id": schedule.groupId,
                "enable": enabled
            ], timeout: 20)
            guard reply["ok"] as? Bool == true else {
                schedulesError = reply["error"] as? String ?? "Could not update schedule."
                return
            }
            schedulesError = nil
            await loadSchedules(for: device)
        } catch {
            schedulesError = error.localizedDescription
        }
    }

    public func deleteSchedule(_ schedule: DeviceSchedule, for device: Device) async {
        do {
            let reply = try await bridge.request([
                "cmd": "scheddel",
                "id": device.id,
                "category": schedule.category,
                "group_id": schedule.groupId
            ], timeout: 20)
            guard reply["ok"] as? Bool == true else {
                schedulesError = reply["error"] as? String ?? "Could not delete schedule."
                return
            }
            schedulesError = nil
            await loadSchedules(for: device)
        } catch {
            schedulesError = error.localizedDescription
        }
    }

    private func applyStatus(_ id: String, decoded: [String: DPSValue]) {
        dpsById[id] = decoded
        statusErrors[id] = nil
        loadedStatus.insert(id)
        if let power = decoded["1"]?.boolValue {
            isOn[id] = power
        }
    }

    public static func decodeDps(_ raw: Any) throws -> [String: DPSValue] {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode([String: DPSValue].self, from: data)
    }

    // MARK: - Writes

    /// Optimistic toggle: flips instantly, then the confirmed reply wins; only
    /// a rejected set reverts to the previous state.
    public func toggle(_ device: Device, to newValue: Bool) async {
        guard device.hasAddress else { return }
        let previous = power(for: device) ?? false
        let previousDps = dpsById[device.id]

        isOn[device.id] = newValue
        dpsById[device.id, default: [:]][ "1"] = .bool(newValue)

        do {
            let reply = try await bridge.request([
                "cmd": "set",
                "id": device.id,
                "dps": ["1": newValue]
            ])
            if reply["ok"] as? Bool == true {
                try applyConfirmedReply(device.id, reply: reply)
                errorText = nil
            } else {
                revert(device: device, isOn: previous, dps: previousDps)
                errorText = reply["error"] as? String ?? "Set failed."
            }
        } catch {
            revert(device: device, isOn: previous, dps: previousDps)
            errorText = error.localizedDescription
        }
    }

    /// Sends an arbitrary DPS patch, optionally painting the expected values
    /// first. On success the reply's confirmed dps is applied immediately; the
    /// device wins over the optimistic value. On failure the previous map is
    /// restored.
    @discardableResult
    public func setDps(
        _ device: Device,
        _ values: [String: Any],
        optimistic: [String: DPSValue] = [:]
    ) async -> Bool {
        guard device.hasAddress else { return false }
        let previousDps = dpsById[device.id]
        let previousOn = isOn[device.id]

        if !optimistic.isEmpty {
            var merged = dpsById[device.id] ?? [:]
            for (key, value) in optimistic {
                merged[key] = value
            }
            dpsById[device.id] = merged
            if let power = merged["1"]?.boolValue {
                isOn[device.id] = power
            }
        }

        do {
            let reply = try await bridge.request([
                "cmd": "set",
                "id": device.id,
                "dps": values
            ])
            if reply["ok"] as? Bool == true {
                try applyConfirmedReply(device.id, reply: reply)
                errorText = nil
                return true
            }
            dpsById[device.id] = previousDps
            isOn[device.id] = previousOn
            errorText = reply["error"] as? String ?? "Set failed."
            return false
        } catch {
            dpsById[device.id] = previousDps
            isOn[device.id] = previousOn
            errorText = error.localizedDescription
            return false
        }
    }

    /// Applies the dps the bridge confirmed from the device after a set. If the
    /// reply carries no dps the optimistic value is left in place.
    private func applyConfirmedReply(_ id: String, reply: [String: Any]) throws {
        guard let raw = reply["dps"] else { return }
        applyStatus(id, decoded: try Self.decodeDps(raw))
    }

    private func revert(device: Device, isOn previousOn: Bool, dps previousDps: [String: DPSValue]?) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            isOn[device.id] = previousOn
            dpsById[device.id] = previousDps
        }
    }
}

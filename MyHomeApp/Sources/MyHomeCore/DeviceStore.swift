// baseline-guard:allow rewrite of existing store for live polling and confirmed writes
import Combine
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

    /// Bridge roster (Tuya + WiFi briturn devices).
    @Published public private(set) var roster: [Device] = [] {
        didSet { invalidateDerivedCaches(roster: true) }
    }
    var bridgeRoster: [Device] = []
    var briturnCloudDevices: [String: BriturnCloudDevice] = [:] {
        didSet { invalidateDerivedCaches() }
    }
    private var isMirroringGroups = false
    private var warnedBridgeOnlyBriturn: Set<String> = []
    @Published public private(set) var briturnCloudSyncing = false
    @Published public internal(set) var briturnCloudError: String?
    @Published public private(set) var briturnCloudDeviceCount = 0
    private var lastBriturnCloudSync: Date?
    private var briturnProbeDone = false
    let briturnCloud: BriturnCloudClient

    /// Raw BLE discoveries currently being heard (from BLEManager).
    @Published public private(set) var bleLights: [BLELight] = [] {
        didSet { invalidateDerivedCaches() }
    }
    /// Every BLE light ever discovered, persisted. BLE bulbs advertise in
    /// bursts — a BLE-only light must NOT vanish from the dashboard just
    /// because its current advert window closed.
    var bleSeen: [String: BLELight] = [:] {
        didSet { invalidateDerivedCaches() }
    }
    private static let bleSeenStorageKey = "briturn.bleSeen"
    /// Uniform view: roster + BLE-only lights. The dedupe is DERIVED here.
    /// Identity rule: a BLE light belongs to a roster entry when the
    /// BLE name suffix matches the roster id's tail
    /// (IOTWF577 ↔ briturn-…8577). One physical light = one card.
    /// BLE-only lights carry their group from app-local persistence (they
    /// have no roster entry to store it in).
    public var devices: [Device] {
        // Cloud is the base once synced: BLE is only a transport attached to cloud lights.
        guard briturnCloudDevices.isEmpty else { return roster }
        // Read by every dashboard body (filters, counts, header): memoized,
        // rebuilt only when an input changes (see invalidateDerivedCaches).
        if let cached = derivedCaches.devices { return cached }
        let built = buildDevices()
        derivedCaches.devices = built
        return built
    }

    private func buildDevices() -> [Device] {
        let bleOnlyDevices = bleSeen.values.sorted { $0.name < $1.name }.compactMap { light -> Device? in
            guard matchRosterID(for: light) == nil else { return nil }
            guard light.id.hasPrefix("ble-") else { return nil }
            return Device(id: light.id, name: light.name, ip: "",
                          version: "BLE", category: "briturn",
                          group: bleGroups[light.id], online: true)
        }
        return roster + bleOnlyDevices
    }

    /// Matches a BLE discovery to its canonical roster id, if it has one.
    /// BLE ids are peripheral UUIDs (no MAC), so the match is the BLE name
    /// suffix (IOTWF577 → roster id ending "577").
    private func matchRosterID(for light: BLELight, in candidates: [Device]? = nil) -> String? {
        let roster = candidates ?? self.roster
        let name = light.name.uppercased()
        for prefix in ["IOTWF", "LEDNETWF", "IOTBT"] where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count)).lowercased()
            guard !suffix.isEmpty else { continue }
            let hits = roster.filter { $0.id.lowercased().hasSuffix(suffix) }
            if hits.count > 1 {
                // The advert name only carries a short tail: several roster ids can share it.
                // Prefer one no other peripheral has claimed yet; otherwise the stable first by id.
                let sorted = hits.sorted { $0.id < $1.id }
                let unclaimed = sorted.first { cand in (self.bleKeysByDeviceID[cand.id] ?? []).allSatisfy { $0 == light.id } }
                let pick = unclaimed ?? sorted[0]
                if loggedAmbiguousBLE.insert(light.id).inserted {
                    AppLog.store.notice("MyHome: BLE name \(light.name, privacy: .public) matches \(hits.count, privacy: .public) roster ids; attaching to \(pick.id, privacy: .public)")
                }
                return pick.id
            }
            if let hit = hits.first { return hit.id }
        }
        return nil
    }
    /// Test seams (internal): the published stores are private(set).
    func cloudOnlineForTest(_ id: String, _ value: Bool?) { cloudOnline[id] = value }
    func setRosterForTest(_ devices: [Device]) { roster = devices }
    private var loggedAmbiguousBLE: Set<String> = []
    /// Memoized per-body derivations (see DeviceStore+DerivedCache.swift).
    var derivedCaches = DerivedCaches()
    private var loggedReachability: [String: Reachability] = [:]

    @Published public internal(set) var isOn: [String: Bool] = [:]
    @Published public internal(set) var dpsById: [String: [String: DPSValue]] = [:]
    @Published public internal(set) var cloudOnline: [String: Bool] = [:]
    /// True when the bridge itself cannot reach the Tuya cloud (e.g. it was
    /// launched with a python env missing `requests`). Distinct from per-device
    /// cloud offline: nothing cloud-backed (schedules, sync) can work until the
    /// app is relaunched so the bridge picks up the venv interpreter.
    @Published public private(set) var cloudEnvBroken = false
    @Published public internal(set) var statusLoading: Set<String> = []
    @Published public internal(set) var statusErrors: [String: String] = [:]
    /// True when that device's latest status reply came over the cloud fallback
    /// (`"via":"cloud"`) rather than the local LAN path. Cleared by the next
    /// successful local status, so it always describes the current reading.
    @Published public internal(set) var statusViaCloud: [String: Bool] = [:]
    @Published public private(set) var schedules: [DeviceSchedule] = []
    @Published public private(set) var schedulesLoading = false
    @Published public private(set) var schedulesError: String?
    @Published public private(set) var errorText: String?
    @Published public private(set) var isWorking = false
    /// Short-lived "Found N new light" message set by the auto-scan (see DeviceStore+AutoScan.swift).
    @Published public internal(set) var newDeviceNotice: String?

    /// Badge text for the independent cloud-connect fact; nil = not fetched.
    public nonisolated static func cloudBadgeText(_ online: Bool?) -> String {
        switch online {
        case .some(true): return "☁ online"
        case .some(false): return "☁ offline"
        case .none: return "☁ …"
        }
    }

    let bridge: any BridgeSending
    /// Snapshot of the Control-tab defaults, read once on start so a poll cycle
    /// never changes cadence mid-flight.
    private let pollInterval: TimeInterval
    private let scanWindow: Int
    var loadedStatus: Set<String> = []
    /// Sweep bookkeeping (never published; see DeviceStore+StatusSweep).
    /// Ids with a status read in flight from ANY path: single-session bulbs
    /// wedge when two sweeps connect at once, so every sweep consults this.
    var statusInFlight: Set<String> = []
    /// Completion time of the last status read attempt per id.
    var lastStatusAt: [String: Date] = [:]
    /// Consecutive failed Briturn LAN probes, and the back-off deadline.
    var lanFailStreak: [String: Int] = [:]
    var lanBackoffUntil: [String: Date] = [:]
    /// objectWillChange counters (see DeviceStore+PublishMeter).
    let publishMeter = PublishMeter()
    private var pollTask: Task<Void, Never>?
    var isAutoScanning = false
    var noticeTask: Task<Void, Never>?
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
    public init(bridge: any BridgeSending = BridgeClient.shared, defaults: UserDefaults = .standard,
                briturnCloud: BriturnCloudClient = .shared) {
        self.briturnCloud = briturnCloud
        self.bridge = bridge
        self.pollInterval = AppSettings.pollInterval(from: defaults)
        self.scanWindow = AppSettings.scanWindow(from: defaults)
        if let data = defaults.data(forKey: Self.bleGroupsStorageKey),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            bleGroups = stored
        }
        if let data = defaults.data(forKey: Self.groupColoursStorageKey),
           let stored = try? JSONDecoder().decode([String: [Int]].self, from: data),
           let rgb = stored["rgb"], rgb.count == 3 {
            // kept simple: stored as [r,g,b] under the group name
        }
        if let raw = defaults.dictionary(forKey: Self.groupColoursStorageKey) as? [String: [Int]] {
            var loaded: [String: (red: Int, green: Int, blue: Int)] = [:]
            for (name, rgb) in raw where rgb.count == 3 {
                loaded[name] = (rgb[0], rgb[1], rgb[2])
            }
            groupColours = loaded
        }
        if let data = defaults.data(forKey: Self.bleSeenStorageKey),
           let stored = try? JSONDecoder().decode([BLELight].self, from: data) {
            for light in Self.migrateBLESeen(stored) { bleSeen[light.id] = light }
        }
        bindBLE()
        startPublishMeter()
    }

    /// Pre-UUID entries ("ble-<12 hex>", derived from advert bytes that
    /// collided across bulbs) can never go live again: drop them. Same-name
    /// entries with UUID ids are different bulbs and are kept apart.
    static func migrateBLESeen(_ stored: [BLELight]) -> [BLELight] {
        stored.filter { light in
            guard light.id.hasPrefix("ble-") else { return false }
            return UUID(uuidString: String(light.id.dropFirst("ble-".count))) != nil
        }
    }

    private func persistBLESeen() {
        if let data = try? JSONEncoder().encode(Array(bleSeen.values)) {
            UserDefaults.standard.set(data, forKey: Self.bleSeenStorageKey)
        }
    }

    func rebuildBriturnRoster() {
        let merged = BriturnCloudDevice.merge(local: bridgeRoster, cloud: Array(briturnCloudDevices.values))
        if !briturnCloudDevices.isEmpty {
            let orphans = Set(bridgeRoster.filter { $0.category.lowercased() == "briturn" && briturnCloudDevices[$0.id] == nil }.map(\.id))
            if orphans != warnedBridgeOnlyBriturn {
                warnedBridgeOnlyBriturn = orphans
                for id in orphans.sorted() { AppLog.store.notice("MyHome: bridge Briturn light \(id, privacy: .public) has no match in the Briturn cloud; showing it from the bridge only") }
            }
        }
        // A BLE-discovered light keeps its app-local group once cloud sync
        // identifies it (matched by MAC or BLE name suffix, like `devices`).
        var matchedGroups: [String: String] = [:]
        for light in bleSeen.values {
            guard let group = bleGroups[light.id], !group.isEmpty,
                  let rosterID = matchRosterID(for: light, in: merged),
                  briturnCloudDevices[rosterID]?.groupName == nil else { continue }
            matchedGroups[rosterID] = group
        }
        roster = merged.map { device in
            guard !bridgeRoster.contains(where: { $0.id == device.id }) else { return device }
            // Cloud group name wins; local groups are only a fallback when the cloud gave none.
            guard briturnCloudDevices[device.id]?.groupName == nil else { return device }
            guard let group = bleGroups[device.id] ?? matchedGroups[device.id] else { return device }
            return Device(id: device.id, name: device.name, ip: device.ip, version: device.version,
                          category: device.category, group: group, online: device.online, room: device.room)
        }
        reattachBLETransports()
    }

    /// Attaches the BLE transport (key + fallback flag) to the roster entry a
    /// BLE light belongs to. Single implementation for discovery, state
    /// updates and roster rebuilds.
    @discardableResult
    private func attachBLE(_ light: BLELight) -> Bool {
        guard let tuyaID = matchRosterID(for: light) else { return false }
        if !bleFallbackIDs.contains(tuyaID) { bleFallbackIDs.insert(tuyaID) }
        // A name suffix can match several peripherals (re-pairing, duplicates):
        // keep every UUID id, resolve the live one at send time. Unchanged
        // keys are not re-assigned (that would drop the derived caches).
        let keys = bleKeysByDeviceID[tuyaID] ?? []
        if !keys.contains(light.id) { bleKeysByDeviceID[tuyaID] = keys + [light.id] }
        return true
    }

    /// The roster can gain entries after BLE discovery (cloud sync adds a
    /// light with no bridge entry): re-run the match so those cards get their
    /// BLE transport.
    func reattachBLETransports() {
        // Sorted: shared-suffix claims must not depend on dictionary order.
        for light in bleSeen.values.sorted(by: { $0.id < $1.id }) { attachBLE(light) }
        for light in bleLights { attachBLE(light) }
    }

    /// Sends one `briturngroup` request and, on success, mirrors it into the
    /// local bridge roster. Failures are logged; the caller retries next cycle.
    @discardableResult
    private func pushBridgeGroup(id: String, group: String) async -> Bool {
        do {
            let reply = try await bridge.request(["cmd": "briturngroup", "id": id, "group": group], timeout: 10)
            guard reply["ok"] as? Bool == true else {
                AppLog.store.notice("MyHome: bridge refused group '\(group, privacy: .public)' for \(id, privacy: .public)")
                return false
            }
        } catch {
            AppLog.store.error("MyHome: bridge group push for \(id, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            return false
        }
        guard let index = bridgeRoster.firstIndex(where: { $0.id == id }) else { return true }
        let old = bridgeRoster[index]
        bridgeRoster[index] = Device(id: old.id, name: old.name, ip: old.ip, version: old.version,
                                     category: old.category, group: group, online: old.online,
                                     spec: old.spec, codes: old.codes, room: old.room)
        return true
    }

    /// Cloud is the base: the bridge resolves group control by NAME from its
    /// own devices.json, so every bridge-known Briturn light is brought to its
    /// cloud group name. Only differing lights are pushed; lights without a
    /// cloud group are left alone.
    func mirrorCloudGroupsToBridge() async {
        guard !isMirroringGroups, !briturnCloudDevices.isEmpty else { return }
        isMirroringGroups = true
        defer { isMirroringGroups = false }
        var changed = false
        for device in bridgeRoster where device.category.lowercased() == "briturn" {
            guard let cloudName = briturnCloudDevices[device.id]?.groupName, !cloudName.isEmpty,
                  (device.group ?? "") != cloudName else { continue }
            if await pushBridgeGroup(id: device.id, group: cloudName) { changed = true }
        }
        if changed { rebuildBriturnRoster() }
    }

    public func isBriturnCloudAvailable(for device: Device) -> Bool {
        briturnCloudDevices[device.id]?.supportsLighting == true
    }

    public enum Reachability: Equatable {
        case wifi, cloud, bluetooth, offline
    }

    /// Single answer to "how can the Mac reach this light right now?", built
    /// from existing facts only. `.offline` means NO control path at the moment:
    /// no online LAN address, cloud not online, and no LIVE Bluetooth peripheral.
    public func reachability(for device: Device) -> Reachability {
        let bleLive = isBLELive(for: device)
        let cloud = cloudOnline[device.id]
        let lan = device.hasAddress && device.online
        // A bridge "online" flag is only the last devices.json state: when the cloud says the
        // light is offline and a live Bluetooth peripheral exists, the LAN address is stale.
        let result: Reachability
        if lan && !(cloud == false && bleLive) { result = .wifi }
        else if (cloud ?? briturnCloudDevices[device.id]?.online) == true,
                isBriturnCloudAvailable(for: device) { result = .cloud }
        else if bleLive { result = .bluetooth }
        else { result = .offline }
        if loggedReachability[device.id] != result {
            loggedReachability[device.id] = result
            let keyCount = (bleKeysByDeviceID[device.id] ?? []).count
            let cloudText = cloud.map { $0 ? "true" : "false" } ?? "nil"
            AppLog.store.notice("MyHome: reachability id=\(device.id, privacy: .public) -> \("\(result)", privacy: .public) (lan=\(lan, privacy: .public) cloudOnline=\(cloudText, privacy: .public) bleKeys=\(keyCount, privacy: .public) bleLive=\(bleLive, privacy: .public))")
        }
        return result
    }

    /// True when ANY control path exists: LAN address, Bluetooth link (seen
    /// or fallback) or the Briturn cloud. A cloud-offline light next to the
    /// Mac is controllable over Bluetooth, so its UI must not be disabled.
    public func isControllable(for device: Device) -> Bool {
        device.hasAddress || isBLEAvailable(for: device) || isBriturnCloudAvailable(for: device)
    }

    @discardableResult
    public func syncBriturnCloud(force: Bool = true) async -> Int {
        guard !briturnCloudSyncing else { return briturnCloudDeviceCount }
        if !force, let last = lastBriturnCloudSync, Date().timeIntervalSince(last) < 60 { return briturnCloudDeviceCount }
        briturnCloudSyncing = true
        defer { briturnCloudSyncing = false }
        do {
            let devices = try await briturnCloud.syncDevices()
            let oldIDs = Set(briturnCloudDevices.keys)
            briturnCloudDevices = Dictionary(devices.map { ($0.canonicalID, $0) }, uniquingKeysWith: { first, _ in first })
            briturnCloudDeviceCount = devices.count
            for id in oldIDs.subtracting(briturnCloudDevices.keys) {
                cloudOnline[id] = nil
                statusViaCloud[id] = nil
                if !bridgeRoster.contains(where: { $0.id == id }) { setBriturnStatus(id, nil); statusErrors[id] = nil }
            }
            for item in devices { cloudOnline[item.canonicalID] = item.online }
            rebuildBriturnRoster()
            lastBriturnCloudSync = Date()
            briturnCloudError = nil
            await mirrorCloudGroupsToBridge()
            await writeBriturnGroupsProbe()
            await refreshBriturnCloudStates(for: roster.filter { briturnCloudDevices[$0.id] != nil })
        } catch {
            briturnCloudError = (error as? BriturnCloudError)?.localizedDescription ?? "Could not sync Briturn Cloud."
        }
        return briturnCloudDeviceCount
    }

    /// The diagnostic probe makes ~8 extra cloud calls, so it only runs when this env var is "1".
    static let briturnProbeEnvVar = "MYHOME_BRITURN_PROBE"
    static func briturnProbeEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[briturnProbeEnvVar] == "1"
    }

    static let briturnProbeFileName = "briturn-groups-probe.json"
    nonisolated private static let briturnProbeSensitiveKey = try! NSRegularExpression(pattern: "token|password|secret|sid|session|email", options: .caseInsensitive)

    /// Recursively drops dictionary keys that could carry credentials or identity.
    nonisolated static func strippingSensitiveKeys(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.filter { key, _ in
                briturnProbeSensitiveKey.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) == nil
            }.mapValues(strippingSensitiveKeys)
        }
        if let array = value as? [Any] { return array.map(strippingSensitiveKeys) }
        return value
    }

    /// Read-only diagnostic: dumps the raw group/room replies once per launch so the
    /// real cloud shape can be inspected. Failures are logged and never break sync.
    private func writeBriturnGroupsProbe() async {
        guard Self.briturnProbeEnabled(), !briturnProbeDone else { return }
        briturnProbeDone = true
        do {
            let raw = try await briturnCloud.probeGroups()
            guard !raw.isEmpty, let directory = BridgeClient.bundledDataDirectory() else { return }
            let data = try JSONSerialization.data(withJSONObject: Self.strippingSensitiveKeys(raw),
                                                  options: [.prettyPrinted, .sortedKeys])
            let url = directory.appendingPathComponent(Self.briturnProbeFileName)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            AppLog.store.error("Briturn groups probe failed: \(String(describing: error), privacy: .private)")
        }
    }

    @discardableResult
    private func controlBriturnCloud(_ devices: [Device], on: Bool?,
                                    color: (red: Int, green: Int, blue: Int)?, brightness: Int?,
                                    white: Bool = false, cct: Int?) async -> Bool {
        let mapped = devices.compactMap { briturnCloudDevices[$0.id] }
        guard mapped.count == devices.count, !mapped.isEmpty else { return false }
        AppLog.store.notice("MyHome: Briturn route=cloud devices=\(mapped.count, privacy: .public)")
        let ids = Set(devices.map(\.id))
        statusLoading.formUnion(ids)
        defer { statusLoading.subtract(ids) }
        do {
            let states: [String: BriturnState]
            if let hook = briturnCloudControlHook {
                states = try await hook(mapped, on)
            } else {
                states = try await briturnCloud.control(devices: mapped, on: on, color: color,
                                                       brightness: brightness, white: white, cct: cct)
            }
            for (id, state) in states {
                applyBriturnWireState(id, state, authoritative: true)
                statusViaCloud[id] = true
                statusErrors[id] = nil
                cloudOnline[id] = true
            }
            let missing = ids.subtracting(states.keys)
            for id in missing { statusErrors[id] = "The light did not confirm cloud control. It may be offline." }
            briturnCloudError = missing.isEmpty ? nil : "\(missing.count) light(s) did not confirm cloud control."
            return missing.isEmpty
        } catch {
            let message = (error as? BriturnCloudError)?.localizedDescription ?? "Could not control the light through Briturn Cloud."
            for id in ids { briturnIntent[id] = nil; statusErrors[id] = message }
            briturnCloudError = message
            return false
        }
    }

    // MARK: - BLE transport

    private var cancellables = Set<AnyCancellable>()
    /// Roster device ids (briturn-<mac>) that BLE has confirmed in range.
    /// These are DUAL-MODE lights: BLE enriches the WiFi entry as a fallback
    /// transport — it never creates a duplicate card.
    var bleFallbackIDs: Set<String> = []
    /// Test seams (internal): replace the cloud control call / the BLE send.
    var briturnCloudControlHook: (([BriturnCloudDevice], Bool?) async throws -> [String: BriturnState])?
    var briturnBLESendHook: ((String, Bool?) -> Void)? {
        didSet { invalidateDerivedCaches() }
    }
    /// Candidate bleKeys ("ble-<peripheral uuid>") per roster id, for addressing BLEManager.
    var bleKeysByDeviceID: [String: [String]] = [:] {
        didSet { invalidateDerivedCaches() }
    }
    /// Test seam (internal): overrides whether a BLE key has a live peripheral.
    var bleLiveHook: ((String) -> Bool)? {
        didSet { invalidateDerivedCaches() }
    }
    /// Test seam (internal): overrides when a BLE key's last advert was heard.
    var bleLastAdvertHook: ((String) -> Date?)?
    /// Group assignment for BLE-only lights. The roster can't hold these (no
    /// bridge entry), so the app persists them locally — same feature surface,
    /// different storage.
    @Published public private(set) var bleGroups: [String: String] = [:] {
        didSet { invalidateDerivedCaches() }
    }
    private static let bleGroupsStorageKey = "briturn.bleGroups"
    /// Last user-chosen colour per group, persisted. The chip shows THIS at
    /// launch — bulbs get swept by polls after, and their leftover colours
    /// (test residue, app-side changes) must never repaint the chip red.
    @Published public private(set) var groupColours: [String: (red: Int, green: Int, blue: Int)] = [:]
    private static let groupColoursStorageKey = "briturn.groupColours"

    /// The BLE key for a device: its own entry if BLE-only, else the matched
    /// WiFi roster id's MAC-derived key.
    private func bleKey(for device: Device) -> String? {
        if device.isBLE { return device.id }
        let candidates = bleKeysByDeviceID[device.id] ?? []
        guard !candidates.isEmpty else { return nil }
        // Prefer a candidate BLEManager currently holds a peripheral for
        // (strongest signal first); otherwise the first candidate.
        let rssi = Dictionary(BLEManager.shared.lights.map { ($0.id, $0.rssi) }, uniquingKeysWith: { a, _ in a })
        let live = candidates.filter { isBLEKeyLive($0) }
            .max { (rssi[$0] ?? Int.min) < (rssi[$1] ?? Int.min) }
        return live ?? candidates[0]
    }

    func isBLEKeyLive(_ key: String) -> Bool {
        if let hook = bleLiveHook { return hook(key) }
        if briturnBLESendHook != nil { return true }
        return BLEManager.shared.hasPeripheral(id: key)
    }

    static let bleUnreachableMessage = BLEReason.notSeen

    /// Test seam (internal): replaces the live BLEManager diagnostics.
    var bleDiagnosticsHook: BLEDiagnostics?

    private var bleDiagnostics: BLEDiagnostics { bleDiagnosticsHook ?? BLEManager.shared.diagnostics }

    /// True when a candidate peripheral for this light was discovered THIS run
    /// (`isBLEAvailable` also counts persisted history).
    public func isBLELive(for device: Device) -> Bool {
        // O(1) after the first call: cards ask this on every body evaluation.
        if let cached = derivedCaches.bleLive[device.id] { return cached }
        let live = computeBLELive(for: device)
        derivedCaches.bleLive[device.id] = live
        return live
    }

    private func computeBLELive(for device: Device) -> Bool {
        if let key = bleKey(for: device), isBLEKeyLive(key) { return true }
        // Attach timing must not matter: re-derive the match from the live adverts.
        guard !device.isBLE else { return false }
        var seen = Set<String>()
        for light in bleLights + Array(bleSeen.values) where seen.insert(light.id).inserted {
            guard isBLEKeyLive(light.id), matchRosterID(for: light) == device.id else { continue }
            attachBLE(light)
            return true
        }
        return false
    }

    /// The real reason Bluetooth cannot reach `device` right now.
    func bleUnreachableReason(for device: Device) -> String {
        BLEReason.message(bleDiagnostics, lightLive: isBLELive(for: device))
    }

    private func bindBLE() {
        let ble = BLEManager.shared
        ble.$lights
            .receive(on: RunLoop.main)
            .sink { [weak self] lights in
                guard let self else { return }
                if self.bleLights != lights { self.bleLights = lights }
                // Cumulative memory: once seen, a BLE light stays on the
                // dashboard (persisted across launches) even when its advert
                // window closes.
                var changed = false
                for light in lights where self.bleSeen[light.id] != light {
                    self.bleSeen[light.id] = light
                    changed = true
                }
                if changed { self.persistBLESeen() }
                // Side effects only — the dedupe itself is derived in
                // `devices` via matchRosterID.
                for light in lights { self.attachBLE(light) }
            }
            .store(in: &cancellables)
        // BLEManager publishes states only when a decoded value changed
        // (coalesced, <= 2 Hz); the tick re-reconciles pending user intents
        // so a lost command still self-corrects while adverts keep coming.
        ble.$states
            .receive(on: RunLoop.main)
            .sink { [weak self] states in self?.reconcileBLEStates(states, pendingIntentsOnly: false) }
            .store(in: &cancellables)
        ble.advertTick
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.reconcileBLEStates(ble.states, pendingIntentsOnly: true) }
            .store(in: &cancellables)
        // Adverts stop when a light leaves range, so expiry cannot rely on the
        // states sink firing: sweep on the BLE summary cadence.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(BLEManager.summaryInterval * 1_000_000_000))
                self?.pruneStaleBLEState()
            }
        }
    }

    private func saveGroupColour(_ group: String, _ color: (red: Int, green: Int, blue: Int)) {
        var stored = groupColours
        stored[group] = (color.red, color.green, color.blue)
        groupColours = stored
        let raw = stored.mapValues { [$0.red, $0.green, $0.blue] }
        UserDefaults.standard.set(raw, forKey: Self.groupColoursStorageKey)
    }

    // MARK: - Briturn schedules (on-bulb timers)

    public struct BriturnTimer: Identifiable, Equatable, Codable {
        public var id: UUID
        public var time: String        // "HH:MM"
        public var days: [String]      // mon..sun, empty = not set
        public var action: String      // "on" | "off" | "colour"
        public var r: Int
        public var g: Int
        public var b: Int

        public init(id: UUID = UUID(), time: String, days: [String],
                    action: String, r: Int = 0, g: Int = 0, b: Int = 0) {
            self.id = id
            self.time = time
            self.days = days
            self.action = action
            self.r = r
            self.g = g
            self.b = b
        }
    }

    @Published public private(set) var briturnTimers: [String: [BriturnTimer]] = [:]
    @Published public private(set) var briturnTimersLoading: Set<String> = []

    public func loadBriturnTimers(for device: Device) async {
        guard isBriturn(device), !device.isBLE, device.hasAddress else { return }
        briturnTimersLoading.insert(device.id)
        defer { briturnTimersLoading.remove(device.id) }
        do {
            let reply = try await bridge.request(["cmd": "briturntimers", "id": device.id], timeout: 15)
            guard reply["ok"] as? Bool == true, let raw = reply["timers"] as? [[String: Any]] else {
                statusErrors[device.id] = reply["error"] as? String ?? "Schedule read failed."
                return
            }
            let timers = raw.compactMap { entry -> BriturnTimer? in
                guard let time = entry["time"] as? String,
                      let active = entry["active"] as? Bool, active,
                      let action = entry["action"] as? String else { return nil }
                let days = (entry["days"] as? [String]) ?? []
                return BriturnTimer(time: time, days: days, action: action,
                                    r: entry["r"] as? Int ?? 0,
                                    g: entry["g"] as? Int ?? 0,
                                    b: entry["b"] as? Int ?? 0)
            }
            briturnTimers[device.id] = timers
            statusErrors[device.id] = nil
        } catch {
            // Quiet-stale like status: schedules stay on the bulb regardless.
            if briturnTimers[device.id] == nil {
                statusErrors[device.id] = error.localizedDescription
            }
        }
    }

    /// Saves the full schedule (max 6) to one light. Bulb clock is synced by
    /// the bridge on every write.
    public func saveBriturnTimers(_ device: Device, timers: [BriturnTimer]) async -> Bool {
        guard isBriturn(device), !device.isBLE else { return false }
        let payload: [[String: Any]] = timers.prefix(6).map { timer in
            var entry: [String: Any] = [
                "time": timer.time,
                "days": timer.days,
                "action": timer.action
            ]
            if timer.action == "colour" {
                entry["r"] = timer.r
                entry["g"] = timer.g
                entry["b"] = timer.b
            }
            return entry
        }
        do {
            let reply = try await bridge.request([
                "cmd": "briturntimerset", "id": device.id, "timers": payload
            ], timeout: 30)
            guard reply["ok"] as? Bool == true else {
                statusErrors[device.id] = reply["error"] as? String ?? "Schedule save failed."
                return false
            }
            if let raw = reply["timers"] as? [[String: Any]] {
                let timers = raw.compactMap { entry -> BriturnTimer? in
                    guard let time = entry["time"] as? String,
                          let active = entry["active"] as? Bool, active,
                          let action = entry["action"] as? String else { return nil }
                    return BriturnTimer(time: time, days: (entry["days"] as? [String]) ?? [],
                                        action: action, r: entry["r"] as? Int ?? 0,
                                        g: entry["g"] as? Int ?? 0, b: entry["b"] as? Int ?? 0)
                }
                briturnTimers[device.id] = timers
            }
            statusErrors[device.id] = nil
            return true
        } catch {
            statusErrors[device.id] = error.localizedDescription
            return false
        }
    }

    /// Writes the same schedule to every member of a group.
    public func saveBriturnGroupTimers(_ group: String, timers: [BriturnTimer]) async -> Bool {
        let payload: [[String: Any]] = timers.prefix(6).map { timer in
            var entry: [String: Any] = ["time": timer.time, "days": timer.days, "action": timer.action]
            if timer.action == "colour" {
                entry["r"] = timer.r
                entry["g"] = timer.g
                entry["b"] = timer.b
            }
            return entry
        }
        do {
            let reply = try await bridge.request([
                "cmd": "briturntimersetgroup", "group": group, "timers": payload
            ], timeout: 90)
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Group schedule failed."
                return false
            }
            errorText = nil
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
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
            capabilities: capabilities(for: device),
            codes: device.codes ?? [:]
        )
    }

    /// nil until a fetch (or confirmed write) has reported dps 1.
    public func power(for device: Device) -> Bool? {
        if isBriturn(device) { return briturnStatus[device.id]?.on }
        return isOn[device.id] ?? dpsById[device.id]?["1"]?.boolValue
    }

    public func dps(for device: Device) -> [String: DPSValue] {
        dpsById[device.id] ?? [:]
    }

    public func isLoadingStatus(_ device: Device) -> Bool {
        statusLoading.contains(device.id)
    }

    // MARK: - List / rescan

    public func refresh() async {
        await syncBriturnCloud(force: false)
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
            bridgeRoster = decoded
            rebuildBriturnRoster()
            await adoptBLEGroups()
            await mirrorCloudGroupsToBridge()
            // Deliberately no isOn default: unknown power stays indeterminate
            // until status arrives.
            errorText = nil
            requestSpecsIfNeeded()
            requestCodeMapIfNeeded()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// A light grouped while BLE-only keeps that group once cloud sync gives
    /// it a roster entry: push it to the bridge (unless the roster already
    /// has one) and drop the app-local copy.
    private func adoptBLEGroups() async {
        guard !bleGroups.isEmpty else { return }
        var groups = bleGroups
        for light in bleSeen.values {
            guard let group = groups[light.id], !group.isEmpty,
                  let rosterID = matchRosterID(for: light),
                  let index = bridgeRoster.firstIndex(where: { $0.id == rosterID }) else { continue }
            if (bridgeRoster[index].group ?? "").isEmpty {
                guard await pushBridgeGroup(id: rosterID, group: group) else { continue }
            }
            groups.removeValue(forKey: light.id)
        }
        guard groups.count != bleGroups.count else { return }
        bleGroups = groups
        rebuildBriturnRoster()
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: Self.bleGroupsStorageKey)
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
        /// Cool-white channel (state frame byte 11); 0 when unknown.
        public let cool: Int
        /// Bulb firmware (state frame byte 10); 0 when unknown.
        public let firmware: Int

        /// Combined white output 0-255 (warm + cool), for brightness display.
        public var whiteLevel: Int { min(w + cool, 255) }

        init(on: Bool, rawPower: Int, mode: Int, r: Int, g: Int, b: Int, w: Int, cool: Int = 0, firmware: Int = 0) {
            self.on = on
            self.rawPower = rawPower
            self.mode = mode
            self.r = r
            self.g = g
            self.b = b
            self.w = w
            self.cool = cool
            self.firmware = firmware
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
            self.cool = reply["cool"] as? Int ?? 0
            self.firmware = reply["firmware"] as? Int ?? 0
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
    /// INVARIANT: USER INTENT OUTRANKS A STALE WIRE READ, per channel.
    /// A wire read may only repaint a channel the user just commanded when it
    /// agrees with what was painted (tolerance-aware for scaled values) or
    /// when the grace has expired / the read is authoritative. Channels the
    /// user did not touch are never defended. Brightness `w` is a percent×2.55
    /// rounded int, so agreement is ±4; colour channels echo raw, so exact.
    private struct BriturnIntent {
        var on: Bool?
        var w: Int?
        var color: (r: Int, g: Int, b: Int)?
        let at: Date
    }

    private var briturnIntent: [String: BriturnIntent] = [:]
    private static let briturnIntentGrace: TimeInterval = 8
    /// `w` is `percent × 2.55` rounded to Int; device echo may drift by a
    /// point or two, so agreement is a band, not equality.
    private static let briturnBrightnessTolerance = 4

    /// General rule: USER INTENT OUTRANKS A STALE WIRE READ — for DPS values
    /// too. A set command paints its optimistic value, but the bridge's
    /// immediate readback (and any poll landing mid-transition) can still
    /// report the OLD value; painting that reply would visually undo the
    /// user's command until the next poll corrects it. An intent records the
    /// dps the user asked for; incoming dps that contradict a fresh intent are
    /// dropped (the intent value is painted instead), agreeing values confirm
    /// and clear their keys, and only after the grace expires does the wire
    /// win — so a genuinely lost command still self-corrects via polling.
    /// Instances: fan speed dots (set-reply AND polls), oscillation toggle,
    /// ModeMenu string enums, and bulb dp sets via SpecControls.
    private struct DpsIntent {
        let values: [String: DPSValue]
        let at: Date
    }

    private var dpsIntent: [String: DpsIntent] = [:]
    private static let dpsIntentGrace: TimeInterval = briturnIntentGrace

    /// Roster ids whose `briturnStatus` came from Bluetooth advertisements
    /// (not WiFi/cloud), with the time it was last refreshed.
    private var bleDerivedStatus: [String: Date] = [:]
    /// BLE id ("ble-<uuid>") whose advert last painted each BLE-derived id.
    private var bleDerivedSource: [String: String] = [:]
    /// A BLE-derived reading older than this is unknown again: twice the BLE
    /// summary interval, since live adverts refresh it far more often.
    static let bleStateMaxAge: TimeInterval = 2 * BLEManager.summaryInterval

    /// Paints an advertisement-decoded state, but only where no WiFi/cloud
    /// reading exists (or the current reading is itself BLE-derived), through
    /// the same intent-aware path as every other wire state.
    func applyBLEDerivedState(_ id: String, _ state: BriturnState, now: Date = Date(), source: String? = nil) {
        guard briturnStatus[id] == nil || bleDerivedStatus[id] != nil else { return }
        applyBriturnWireState(id, state)
        bleDerivedStatus[id] = now
        if let source { bleDerivedSource[id] = source }
    }

    /// Paints BLE advert states. `pendingIntentsOnly` (the advert tick) only
    /// revisits ids with an unconfirmed user intent; nothing else can change
    /// when the decoded states themselves did not.
    func reconcileBLEStates(_ states: [String: BriturnState], pendingIntentsOnly: Bool) {
        if pendingIntentsOnly && briturnIntent.isEmpty { return }
        for (bleID, state) in states {
            guard let light = bleLights.first(where: { $0.id == bleID }) ?? bleSeen[bleID] else { continue }
            // General rule: advertisement-decoded state is ONLY used
            // for lights whose sole transport is Bluetooth. For
            // dual-mode lights the WiFi poll is authoritative and the
            // advert colour bytes decoded wrong on this firmware —
            // painting them made launch colours go wild.
            let target: String
            if attachBLE(light) {
                // Dual-mode: only fills a light with NO cloud/WiFi
                // status yet; never overrides an authoritative read.
                guard let rosterID = matchRosterID(for: light) else { continue }
                target = rosterID
            } else {
                target = bleID
            }
            if pendingIntentsOnly && briturnIntent[target] == nil { continue }
            applyBLEDerivedState(target, state, source: bleID)
        }
    }

    /// Drops BLE-derived readings that have not been refreshed recently so a
    /// light that left range shows unknown, not a stale on/off or brightness.
    /// Freshness is the later of the last paint and the last advert heard
    /// from the feeding peripheral (unchanged adverts are not republished).
    func pruneStaleBLEState(now: Date = Date()) {
        for (id, at) in bleDerivedStatus {
            let heard = bleDerivedSource[id].flatMap { bleLastAdvert($0) }
            let fresh = max(at, heard ?? at)
            guard now.timeIntervalSince(fresh) > Self.bleStateMaxAge else { continue }
            bleDerivedStatus[id] = nil
            bleDerivedSource[id] = nil
            setBriturnStatus(id, nil)
        }
    }

    /// The single write path for `briturnStatus`: equal values (including
    /// nil over an absent key) never fire objectWillChange.
    func setBriturnStatus(_ id: String, _ state: BriturnState?) {
        guard briturnStatus[id] != state else { return }
        briturnStatus[id] = state
    }

    /// Paints a wire-read state unless it fights a fresh user intent, judged
    /// channel by channel: on/colour exactly, brightness within tolerance.
    func applyBriturnWireState(_ id: String, _ state: BriturnState, authoritative: Bool = false) {
        if let paint = resolveBriturnWireState(id, state, authoritative: authoritative) {
            setBriturnStatus(id, paint)
        }
    }

    /// Batch form of applyBriturnWireState for sweeps: same per-light intent
    /// rule, but `briturnStatus` is assigned at most ONCE (and not at all
    /// when nothing changed), so a sweep is one invalidation, not one per light.
    func applyBriturnWireStates(_ states: [String: BriturnState]) {
        guard !states.isEmpty else { return }
        var next = briturnStatus
        for (id, state) in states {
            if let paint = resolveBriturnWireState(id, state, authoritative: false) { next[id] = paint }
        }
        if next != briturnStatus { briturnStatus = next }
    }

    /// The intent rule itself: returns the state to paint, or nil when the
    /// read contradicts a fresh user intent and must be dropped.
    private func resolveBriturnWireState(_ id: String, _ state: BriturnState, authoritative: Bool) -> BriturnState? {
        bleDerivedStatus[id] = nil
        guard var intent = briturnIntent[id] else {
            return state
        }
        guard Date().timeIntervalSince(intent.at) < Self.briturnIntentGrace else {
            // Grace expired: the wire wins for every channel.
            briturnIntent.removeValue(forKey: id)
            return state
        }
        var contradicts = false
        if let want = intent.on {
            if state.on == want || authoritative {
                intent.on = nil
            } else {
                contradicts = true
            }
        }
        if let want = intent.w {
            if abs(state.whiteLevel - want) <= Self.briturnBrightnessTolerance || authoritative {
                intent.w = nil
            } else {
                contradicts = true
            }
        }
        if let want = intent.color {
            if (state.r == want.r && state.g == want.g && state.b == want.b) || authoritative {
                intent.color = nil
            } else {
                contradicts = true
            }
        }
        if contradicts && !authoritative {
            // Mid-transition poll: keep showing what the user painted, but
            // retain the channels the device already confirmed.
            briturnIntent[id] = intent
            return nil
        }
        // Confirmed on every touched channel, or the authoritative readback
        // says the command never took: the wire is the truth.
        briturnIntent.removeValue(forKey: id)
        return state
    }

    /// The intent snapshot for what a setter just painted: only the channels
    /// the user actually commanded, using the painted values themselves. A
    /// brightness command on a colour-mode light is carried by the scaled RGB
    /// it painted; on a white-mode light by `w`.
    private func briturnIntentSnapshot(
        on: Bool?,
        color: (red: Int, green: Int, blue: Int)?,
        brightness: Int?,
        paintedWhite: Bool,
        painted: BriturnState
    ) -> BriturnIntent {
        let paintedColor: (r: Int, g: Int, b: Int)?
        if let color = color {
            paintedColor = (r: color.red, g: color.green, b: color.blue)
        } else if brightness != nil && !paintedWhite {
            paintedColor = (r: painted.r, g: painted.g, b: painted.b)
        } else {
            paintedColor = nil
        }
        return BriturnIntent(
            on: on,
            w: paintedWhite ? painted.w : nil,
            color: paintedColor,
            at: Date()
        )
    }

    func isBriturn(_ device: Device) -> Bool {
        device.category.lowercased() == "briturn"
    }

    public func loadBriturnStatus(for device: Device) async {
        guard isBriturn(device) else { return }
        // BLE lights state-source from advertisements via BLEManager.
        guard !device.isBLE else { return }
        guard device.hasAddress else {
            await refreshBriturnCloudStates(for: [device])
            return
        }
        // A sweep already has this bulb's single session: its result lands
        // in briturnStatus shortly, so a second connect would only wedge it.
        guard !statusInFlight.contains(device.id) else { return }
        statusInFlight.insert(device.id)
        // NATIVE TRANSPORT: query the light directly.
        let queried = await FluxClient.query(ip: device.ip)
        statusInFlight.remove(device.id)
        lastStatusAt[device.id] = Date()
        guard let state = queried else {
            if briturnCloudDevices[device.id] != nil {
                await refreshBriturnCloudStates(for: [device])
                return
            }
            // Unreachable: keep last known state; only a never-seen light
            // surfaces the failure.
            if briturnStatus[device.id] == nil {
                statusErrors[device.id] = "Light unreachable."
            }
            return
        }
        noteLANResult(device.id, ok: true)
        applyBriturnWireState(device.id, state)
        if statusViaCloud[device.id] != false { statusViaCloud[device.id] = false }
        if statusErrors[device.id] != nil { statusErrors[device.id] = nil }
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
        white: Bool = false,
        cct: Int? = nil
    ) async {
        guard isBriturn(device) else { return }
        guard on != nil || color != nil || brightness != nil || white || cct != nil else { return }
        if !device.hasAddress, briturnCloudDevices[device.id] != nil {
            await setBriturnCloudOrBLE(device, on: on, color: color, brightness: brightness, white: white, cct: cct)
            return
        }
        // Transport routing: BLE-only lights, and dual-mode lights that lost
        // WiFi (no IP), go over Bluetooth.
        if device.isBLE || (bleFallbackIDs.contains(device.id) && !device.hasAddress) {
            await setBriturnViaBLE(device, on: on, color: color, brightness: brightness,
                                   white: white || cct != nil, cct: cct)
            return
        }
        guard device.hasAddress else {
            statusErrors[device.id] = "Briturn device has no IP yet — run a Briturn scan."
            return
        }
        AppLog.store.notice("MyHome: Briturn route=bridge device=\(device.id, privacy: .public)")
        // CONTROL PATH: the bridge. Group control (briturnsetgroup) is
        // proven working on every light through this exact transport, so
        // individual control uses the same path — no transport doubt. The
        // native FluxClient is then used only for a fast readback reconcile,
        // and only if it happens to be permitted.
        var payload: [String: Any] = ["cmd": "briturnset", "id": device.id]
        if let on = on { payload["on"] = on }
        if let color = color {
            payload["r"] = color.red
            payload["g"] = color.green
            payload["b"] = color.blue
        }
        if let brightness = brightness { payload["brightness"] = brightness }
        if white { payload["w"] = 128 }
        // CCT drives the bulb's real warm/cool white channels (bridge sends
        // the 0x3B 0xB1 packet instead of a colour packet).
        if let cct = cct { payload["cct"] = cct }
        // Optimistic paint from the request.
        let prev = briturnStatus[device.id]
        let nextOn = on ?? (prev?.on ?? false)
        let paintedWhite = white || cct != nil || (color == nil && (prev?.isWhiteMode ?? false) && brightness != nil)
        let paintedW = paintedWhite
            ? brightness.map { min(Int((Double($0) * 2.55).rounded()), 255) }
            : nil
        let painted = BriturnState(
            on: nextOn,
            rawPower: nextOn ? 0x23 : 0x24,
            mode: prev?.mode ?? 97,
            r: paintedWhite ? 0 : (color?.red ?? prev?.r ?? 255),
            g: paintedWhite ? 0 : (color?.green ?? prev?.g ?? 255),
            b: paintedWhite ? 0 : (color?.blue ?? prev?.b ?? 255),
            w: paintedW ?? prev?.w ?? 0
        )
        setBriturnStatus(device.id, painted)
        // Defend exactly what was painted, for every channel the user touched
        // (power, brightness/white, colour) — not just power.
        // CCT readback bytes vary with the temperature, so a CCT set defends
        // power only (no w/colour intent).
        briturnIntent[device.id] = briturnIntentSnapshot(
            on: on, color: color, brightness: cct != nil ? nil : brightness,
            paintedWhite: paintedWhite && cct == nil, painted: painted
        )
        do {
            let reply = try await bridge.request(payload, timeout: 30)
            guard reply["ok"] as? Bool == true else {
                await fallbackToBLEOrFail(device, on: on, color: color, brightness: brightness,
                                          white: white || cct != nil, cct: cct, prev: prev,
                                          message: reply["error"] as? String ?? "Briturn set failed.")
                return
            }
            statusErrors[device.id] = nil
            if let raw = reply["status"] as? [String: Any], let state = BriturnState(reply: raw) {
                applyBriturnWireState(device.id, state, authoritative: true)
            }
        } catch {
            await fallbackToBLEOrFail(device, on: on, color: color, brightness: brightness,
                                      white: white || cct != nil, cct: cct, prev: prev,
                                      message: error.localizedDescription)
        }
    }

    /// True when the cloud reports the light offline (live status first, then
    /// the last sync). Offline in the cloud does not mean out of Bluetooth range.
    func isCloudOffline(_ device: Device) -> Bool {
        if let live = cloudOnline[device.id] { return !live }
        return briturnCloudDevices[device.id]?.online == false
    }

    /// Cloud-known light with no IP. Cloud-offline + Bluetooth in range goes
    /// straight over BLE; otherwise the cloud is tried first and a failure
    /// retries over BLE. Only when neither works does the cloud error surface.
    private func setBriturnCloudOrBLE(
        _ device: Device, on: Bool?, color: (red: Int, green: Int, blue: Int)?,
        brightness: Int?, white: Bool, cct: Int?
    ) async {
        let viaBLEWhite = white || cct != nil
        let bleOK = isBLEAvailable(for: device) && bleKey(for: device) != nil
        if isCloudOffline(device), bleOK {
            statusErrors[device.id] = nil
            await setBriturnViaBLE(device, on: on, color: color, brightness: brightness, white: viaBLEWhite, cct: cct)
            return
        }
        let prev = briturnStatus[device.id]
        if await controlBriturnCloud([device], on: on, color: color, brightness: brightness, white: white, cct: cct) {
            return
        }
        if bleOK {
            statusErrors[device.id] = nil
            await setBriturnViaBLE(device, on: on, color: color, brightness: brightness, white: viaBLEWhite, cct: cct)
            return
        }
        let message = statusErrors[device.id] ?? "Could not control the light through Briturn Cloud."
        statusErrors[device.id] = message + " (Bluetooth not in range for this light.)"
        briturnIntent.removeValue(forKey: device.id)
        setBriturnStatus(device.id, prev)
    }

    /// General rule: when the WiFi transport fails for a dual-mode light that
    /// Bluetooth has seen, the same command is retried over BLE transparently
    /// — the user asked for the light to change, not for a transport lecture.
    /// Only when Bluetooth cannot address it either does the error surface.
    private func fallbackToBLEOrFail(
        _ device: Device, on: Bool?, color: (red: Int, green: Int, blue: Int)?,
        brightness: Int?, white: Bool, cct: Int? = nil, prev: BriturnState?, message: String
    ) async {
        if briturnCloudDevices[device.id] != nil,
           await controlBriturnCloud([device], on: on, color: color, brightness: brightness, white: white, cct: cct) {
            return
        }

        if bleFallbackIDs.contains(device.id), let key = bleKey(for: device) {
            if sendBriturnBLE(key: key, on: on, color: color, brightness: brightness,
                              white: white, cct: cct) {
                statusErrors[device.id] = nil
            } else {
                statusErrors[device.id] = bleUnreachableReason(for: device)
                briturnIntent.removeValue(forKey: device.id)
                setBriturnStatus(device.id, prev)
            }
            return
        }
        statusErrors[device.id] = message + " (Bluetooth not in range for this light.)"
        briturnIntent.removeValue(forKey: device.id)
        setBriturnStatus(device.id, prev)
    }

    /// Transport availability for a briturn device: WiFi (has a routable IP)
    /// and/or Bluetooth (BLE advertisements seen recently). A device can be
    /// reachable over both — dual-mode is the norm for these lights.
    public func isBLEAvailable(for device: Device) -> Bool {
        device.isBLE || bleFallbackIDs.contains(device.id)
    }

    public func isWiFiAvailable(for device: Device) -> Bool {
        device.hasAddress
    }

    // MARK: - Briturn groups

    /// BLE-transport set: same optimistic paint + intent rules as the WiFi
    /// path; reconciliation comes from BLE advertisements instead of a bridge
    /// readback, so a failed command self-corrects on the next advert.
    private func setBriturnViaBLE(
        _ device: Device,
        on: Bool?,
        color: (red: Int, green: Int, blue: Int)?,
        brightness: Int?,
        white: Bool,
        cct: Int? = nil
    ) async {
        guard let key = bleKey(for: device) else {
            statusErrors[device.id] = "Bluetooth not seen for this light yet — is it powered and in range?"
            return
        }
        let ble = BLEManager.shared
        let prev = briturnStatus[device.id]
        guard sendBriturnBLE(key: key, on: on, color: color, brightness: brightness,
                             white: white, cct: cct) else {
            statusErrors[device.id] = bleUnreachableReason(for: device)
            briturnIntent.removeValue(forKey: device.id)
            setBriturnStatus(device.id, prev)
            return
        }

        let nextOn = on ?? (prev?.on ?? false)
        let paintedWhite = white || (color == nil && (prev?.isWhiteMode ?? false) && brightness != nil)
        let paintedW = paintedWhite
            ? brightness.map { min(Int((Double($0) * 2.55).rounded()), 255) }
            : nil
        let painted = BriturnState(
            on: nextOn,
            rawPower: nextOn ? 0x23 : 0x24,
            mode: prev?.mode ?? 97,
            r: paintedWhite ? 0 : (color?.red ?? prev?.r ?? 255),
            g: paintedWhite ? 0 : (color?.green ?? prev?.g ?? 255),
            b: paintedWhite ? 0 : (color?.blue ?? prev?.b ?? 255),
            w: paintedW ?? prev?.w ?? 0
        )
        setBriturnStatus(device.id, painted)
        // Same intent rule as the WiFi path: a CCT set defends power only.
        briturnIntent[device.id] = briturnIntentSnapshot(
            on: on, color: color, brightness: cct != nil ? nil : brightness,
            paintedWhite: paintedWhite && cct == nil, painted: painted
        )
        // Advertised state reconciles; force a delayed re-read of the cache.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, let s = ble.state(for: key) else { return }
            self.applyBriturnWireState(device.id, s)
        }
    }

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

    /// Distinct non-empty Tuya room names across the roster. `room` is the
    /// Tuya location field; Briturn's `group` is fixture metadata with a
    /// different owner and must never surface as a room. Derived not stored.
    public var roomNames: [String] {
        Array(Set(devices.compactMap { device -> String? in
            guard device.category.lowercased() != "briturn" else { return nil }
            let trimmed = device.room.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })).sorted()
    }

    /// Assigns a room to any roster device (nil/empty clears) and re-lists so
    /// chips, badges and the detail view update from one source of truth.
    @discardableResult
    public func setRoom(id: String, room: String?) async -> Bool {
        let value = (room ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 40 else {
            statusErrors[id] = "Room must be 1-40 characters."
            return false
        }
        do {
            let reply = try await bridge.request([
                "cmd": "setroom",
                "id": id,
                "room": value
            ], timeout: 10)
            guard reply["ok"] as? Bool == true else {
                statusErrors[id] = reply["error"] as? String ?? "Room assign failed."
                return false
            }
            statusErrors[id] = nil
            await refresh()
            return true
        } catch {
            statusErrors[id] = error.localizedDescription
            return false
        }
    }

    /// Assigns one device to a group (nil clears) and re-lists so the roster
    /// and every derived view update together.
    public static let briturnCloudGroupMessage = "Groups come from the Briturn cloud — change them in the Briturn app."

    public func setBriturnGroup(_ device: Device, to group: String?) async {
        // Cloud-known lights take their group from the cloud; a local write would be overwritten by the next sync.
        if briturnCloudDevices[device.id] != nil {
            statusErrors[device.id] = Self.briturnCloudGroupMessage
            return
        }
        // BLE-only lights persist their group app-side.
        if device.isBLE {
            var groups = bleGroups
            if let group = group, !group.isEmpty { groups[device.id] = group }
            else { groups.removeValue(forKey: device.id) }
            bleGroups = groups
            rebuildBriturnRoster()
            if let data = try? JSONEncoder().encode(groups) {
                UserDefaults.standard.set(data, forKey: Self.bleGroupsStorageKey)
            }
            return
        }
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
        brightness: Int? = nil,
        cct: Int? = nil
    ) async {
        guard on != nil || color != nil || brightness != nil || cct != nil else { return }
        let memberDevices = members(of: group)
        let cloudMembers = memberDevices.filter { briturnCloudDevices[$0.id] != nil }
        if !cloudMembers.isEmpty {
            // Cloud-offline members that Bluetooth can reach never go to the
            // cloud (it omits them); they get the same command over BLE.
            let bleOnly = cloudMembers.filter { isCloudOffline($0) && isBLEAvailable(for: $0) && bleKey(for: $0) != nil }
            let bleOnlyIDs = Set(bleOnly.map(\.id))
            let viaCloud = cloudMembers.filter { !bleOnlyIDs.contains($0.id) }
            var success = true
            var recovered = Set<String>()
            if !viaCloud.isEmpty {
                success = await controlBriturnCloud(viaCloud, on: on, color: color, brightness: brightness, cct: cct)
                if !success {
                    // Members the cloud did not confirm: retry over BLE where possible.
                    for device in viaCloud where statusErrors[device.id] != nil
                        && isBLEAvailable(for: device) && bleKey(for: device) != nil {
                        recovered.insert(device.id)
                    }
                }
            }
            for device in bleOnly + viaCloud.filter({ recovered.contains($0.id) }) {
                statusErrors[device.id] = nil
                await setBriturnViaBLE(device, on: on, color: color, brightness: brightness,
                                       white: cct != nil, cct: cct)
            }
            for device in memberDevices where briturnCloudDevices[device.id] == nil {
                await setBriturn(device, on: on, color: color, brightness: brightness, cct: cct)
            }
            let unrecovered = viaCloud.contains { statusErrors[$0.id] != nil && !recovered.contains($0.id) }
            if !success && !unrecovered { briturnCloudError = nil }
            errorText = (success || !unrecovered) ? nil : briturnCloudError
            return
        }
        let memberIDs = memberDevices.filter(\.hasAddress).map(\.id)
        var payload: [String: Any] = ["cmd": "briturnsetgroup", "group": group]
        if let on = on { payload["on"] = on }
        if let color = color {
            payload["r"] = color.red
            payload["g"] = color.green
            payload["b"] = color.blue
        }
        if let brightness = brightness { payload["brightness"] = brightness }
        if let cct = cct { payload["cct"] = cct }
        // Optimistic: paint EVERY member from the request plus its OWN prior
        // state — a member with no status yet must still show the group's new
        // state immediately, and a colour-only set must not clobber members'
        // individual power states. Brightness scales each member's own colour.
        var scale: Double = 1
        if let brightness = brightness, color == nil, cct == nil {
            scale = Double(brightness) * 2.55 / Double(
                max(briturnStatus[memberIDs.first ?? ""]?.r ?? 255,
                    briturnStatus[memberIDs.first ?? ""]?.g ?? 0,
                    briturnStatus[memberIDs.first ?? ""]?.b ?? 0, 1)
            )
        }
        for id in memberIDs {
            let prev = briturnStatus[id]
            let nextOn = on ?? (prev?.on ?? false)
            let paintedWhite = cct != nil
                || (color == nil && (prev?.isWhiteMode ?? false) && brightness != nil)
            let paintedW = paintedWhite
                ? brightness.map { min(Int((Double($0) * 2.55).rounded()), 255) }
                : nil
            var r = paintedWhite && cct != nil ? 0 : (color?.red ?? prev?.r ?? 255)
            var g = paintedWhite && cct != nil ? 0 : (color?.green ?? prev?.g ?? 255)
            var b = paintedWhite && cct != nil ? 0 : (color?.blue ?? prev?.b ?? 255)
            if color == nil, brightness != nil, cct == nil {
                r = min(Int(Double(r) * scale), 255)
                g = min(Int(Double(g) * scale), 255)
                b = min(Int(Double(b) * scale), 255)
            }
            let painted = BriturnState(
                on: nextOn,
                rawPower: nextOn ? 0x23 : 0x24,
                mode: prev?.mode ?? 97,
                r: r, g: g, b: b,
                w: paintedW ?? prev?.w ?? 0
            )
            setBriturnStatus(id, painted)
            // Each member defends its OWN painted channels: colour-only sets
            // defend colour, white-mode brightness defends w, and every
            // member keeps its individual power display untouched.
            briturnIntent[id] = briturnIntentSnapshot(
                on: on, color: color, brightness: cct != nil ? nil : brightness,
                paintedWhite: paintedWhite && cct == nil, painted: painted
            )
        }
        do {
            let reply = try await bridge.request(payload, timeout: 30)
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Group set failed."
                // Nothing was applied: drop the defensive intents so the next
                // poll is free to correct the optimistic paint.
                for id in memberIDs { briturnIntent.removeValue(forKey: id) }
                return
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            for id in memberIDs { briturnIntent.removeValue(forKey: id) }
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

    /// Fetch upstream capability metadata once; the bridge caches per device.
    /// General rule: briturn devices have NO DPS surface and their spec/codes
    /// stay nil forever — including them in this gate made the cloud-backed
    /// requests refire on every refresh, hogging the serial bridge and
    /// starving the roster fetch (bridge flap).
    private func needsSpecsOrCodes(_ device: Device) -> Bool {
        !device.isBLE && device.category.lowercased() != "briturn"
    }

    private func requestSpecsIfNeeded() {
        guard !specsFetched, !specsFetching else { return }
        guard devices.contains(where: { needsSpecsOrCodes($0) && $0.spec == nil }) else {
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
        guard devices.contains(where: { needsSpecsOrCodes($0) && $0.codes == nil }) else {
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
        await syncBriturnCloud()
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
                var statuses = try JSONDecoder().decode([String: Bool].self, from: data)
                for item in briturnCloudDevices.values { statuses[item.canonicalID] = cloudOnline[item.canonicalID] ?? item.online }
                cloudOnline = statuses
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

    /// Single intent-reconciliation gate for EVERY wire-read paint.
    ///
    /// INVARIANT: every wire-read paint — set reply, single fetch, AND batch
    /// poll — passes through this helper. A fresh user command is therefore
    /// never visually undone by a stale read, and after the grace expires the
    /// wire wins again so a genuinely lost command self-corrects. Callers paint
    /// the RETURNED map, never the raw decode (`isOn` included).
    ///
    /// The rule is key-generic, not a set of per-dp special cases: the fan
    /// speed dot (dp3) arriving in a set reply and the power bit (dp1) arriving
    /// in a batch poll are merely two instances. Unseen inputs ride the same
    /// path untouched — e.g. oscillation dp5 in a poll batch, or a curtain's
    /// percent dp (dp2) — because nothing here names a key.
    ///
    /// Mutates `dpsIntent` exactly as the pre-extraction code did: agreeing
    /// keys confirm and are dropped, contradicting keys keep their intent at
    /// the original timestamp, and an expired intent is discarded.
    func reconciled(_ id: String, _ decoded: [String: DPSValue]) -> [String: DPSValue] {
        var resolved = decoded
        if let intent = dpsIntent[id],
           Date().timeIntervalSince(intent.at) < Self.dpsIntentGrace {
            var pending: [String: DPSValue] = [:]
            for (key, intended) in intent.values {
                guard let wire = decoded[key] else { continue }
                if wire == intended {
                    // Device confirmed the user's instruction: stop defending.
                    continue
                }
                // Stale readback: keep showing the user's command.
                resolved[key] = intended
                pending[key] = intended
            }
            if pending.isEmpty {
                dpsIntent.removeValue(forKey: id)
            } else {
                dpsIntent[id] = DpsIntent(values: pending, at: intent.at)
            }
        } else if dpsIntent[id] != nil {
            // Grace expired: the wire is authoritative again.
            dpsIntent.removeValue(forKey: id)
        }
        return resolved
    }

    func applyStatus(
        _ id: String,
        decoded: [String: DPSValue],
        viaCloud: Bool = false
    ) {
        let resolved = reconciled(id, decoded)
        dpsById[id] = resolved
        statusViaCloud[id] = viaCloud
        statusErrors[id] = nil
        loadedStatus.insert(id)
        if let power = resolved["1"]?.boolValue {
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
        if isBriturn(device) {
            await setBriturn(device, on: newValue)
            return
        }
        guard device.hasAddress else { return }
        let previous = power(for: device) ?? false
        let previousDps = dpsById[device.id]

        isOn[device.id] = newValue
        dpsById[device.id, default: [:]][ "1"] = .bool(newValue)
        // Defend the optimistic paint from stale polls/set replies, exactly
        // like setDps does for arbitrary dps patches.
        dpsIntent[device.id] = DpsIntent(values: ["1": .bool(newValue)], at: Date())

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
                let message = reply["error"] as? String ?? "Set failed."
                if Self.isDefiniteRejection(message) {
                    dpsIntent.removeValue(forKey: device.id)
                    revert(device: device, isOn: previous, dps: previousDps)
                }
                // Ambiguous outcome (transport/914/etc.): keep the optimistic
                // paint and the intent -- see the invariant in setDps.
                errorText = message
            }
        } catch {
            // No reply at all is an unknown outcome, not evidence of failure:
            // leave the optimistic paint and intent for the next poll to
            // confirm or let the grace window self-correct.
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
            // A newer command supersedes any prior intent for this device.
            dpsIntent[device.id] = DpsIntent(values: optimistic, at: Date())
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
            // Reversion rule (invariant): an UNKNOWN outcome is not evidence
            // of failure. Only a definite rejection may undo the user's paint
            // and clear the intent; a thrown transport error or an ambiguous
            // device message (902/914/timeout/connection) must keep both, so
            // the pending poll can confirm what the device actually applied
            // and the grace window can self-correct if it never does.
            let message = reply["error"] as? String ?? "Set failed."
            if Self.isDefiniteRejection(message) {
                dpsById[device.id] = previousDps
                isOn[device.id] = previousOn
                dpsIntent.removeValue(forKey: device.id)
            }
            errorText = message
            return false
        } catch {
            // Unknown outcome: keep optimistic dps and intent in place.
            errorText = error.localizedDescription
            return false
        }
    }

    /// A failed set is definite only when the bridge explicitly rejected the
    /// request (bad id/ip/dps). Transport-class text -- 902, 914, timeouts,
    /// connection resets -- means the device may have applied the set, so it
    /// must not be treated as a rejection. Any unrecognized text is treated as
    /// ambiguous on purpose: the safe default is to keep the paint.
    private static func isDefiniteRejection(_ message: String) -> Bool {
        let text = message.lowercased()
        let ambiguous = [
            "902", "914", "timeout", "timed out", "time out", "connection",
            "did not respond", "no response", "network is unreachable",
            "no route to host", "broken pipe", "reset by peer", "eof",
            "socket", "unreachable"
        ]
        return !ambiguous.contains { text.contains($0) }
    }

    /// Applies the dps the bridge confirmed from the device after a set. If the
    /// reply carries no dps the optimistic value is left in place.
    private func applyConfirmedReply(_ id: String, reply: [String: Any]) throws {
        guard let raw = reply["dps"] else { return }
        applyStatus(
            id,
            decoded: try Self.decodeDps(raw),
            viaCloud: reply["via"] as? String == "cloud"
        )
    }

    private func revert(device: Device, isOn previousOn: Bool, dps previousDps: [String: DPSValue]?) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            isOn[device.id] = previousOn
            dpsById[device.id] = previousDps
        }
    }
}

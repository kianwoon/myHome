// Status sweeps: launch load, poll cycle, detail fetch and dashboard switch.
//
// General rule: a sweep never serialises unrelated devices. Briturn LAN,
// Briturn cloud and Tuya bridge reads run concurrently, each LAN/bridge sweep
// through a bounded sliding window (the bridge itself runs id-stamped
// requests on worker threads), and results land as ONE compare-before-assign
// write per published collection — an unchanged sweep publishes nothing, so
// the ~50 cards observing the store are not re-evaluated for no reason.
//
// Timing lines (category `store`, all public):
//   MyHome: status refresh scope=<scope>-briturn|<scope>-tuya devices=<n> took=<ms> ...
//   MyHome: dashboard switch scope=<title> visible=<n> stale=<m>

import Foundation

extension DeviceStore {
    /// In-flight bound for direct Briturn LAN queries (bulbs' tiny TCP stacks).
    static let briturnSweepWidth = 8
    /// In-flight bound for bridge `status` requests (bridge has 8 workers).
    static let tuyaSweepWidth = 6
    /// Bridge status timeout: local 5 s socket + one retry + cloud fallback.
    static let statusRequestTimeout: TimeInterval = 15
    /// A dashboard switch re-reads a visible device only when its last read
    /// attempt is older than this; anything fresher is what the poll shows.
    static let switchRefreshMinAge: TimeInterval = 8
    /// Consecutive failed LAN probes before a cloud-backed light backs off.
    static let lanFailStreakThreshold = 2
    /// How long a backed-off light skips the LAN probe and reads the cloud.
    static let lanBackoffInterval: TimeInterval = 60

    enum StatusFetch {
        case success([String: DPSValue], viaCloud: Bool)
        case failure(String)
    }

    // MARK: - Entry points

    /// Launch-time Tuya load: every addressed device not yet loaded, read
    /// concurrently (bounded) and applied in one batch.
    public func loadAllStatuses() async {
        await refreshTuyaStatuses(limitingTo: devices.filter { !loadedStatus.contains($0.id) }, scope: "launch")
    }

    /// Loads every briturn device's wire state once — launch-time parity with
    /// loadAllStatuses, so the on-count and chips are right immediately.
    public func loadAllBriturnStatuses() async {
        await refreshBriturnStatuses(scope: "launch")
    }

    /// One poll: Briturn and Tuya sweeps run side by side, so neither family
    /// waits for the other's slowest (offline) device.
    func pollCycle() async {
        async let briturn: Void = refreshBriturnStatuses(scope: "poll")
        async let speakers: Void = refreshKEFSpeakers()
        async let castSpeakers: Void = refreshCastSpeakers()
        await refreshTuyaStatuses(scope: "poll")
        await briturn
        await speakers
        await castSpeakers
    }

    /// Dashboard category/room/group switch. Cards already render the cached
    /// state synchronously; this only re-reads VISIBLE devices whose last
    /// read is older than `switchRefreshMinAge`, in the background.
    public func dashboardDidSwitch(scope: String, visible: [Device]) {
        let now = Date()
        setKEFVisible(visible)
        setCastVisible(visible)
        let stale = visible.filter { device in
            guard !statusInFlight.contains(device.id), !device.isBLE,
                  device.hasAddress || briturnCloudDevices[device.id] != nil else { return false }
            guard let last = lastStatusAt[device.id] else { return true }
            return now.timeIntervalSince(last) >= Self.switchRefreshMinAge
        }
        AppLog.store.notice("MyHome: dashboard switch scope=\(scope, privacy: .public) visible=\(visible.count, privacy: .public) stale=\(stale.count, privacy: .public)")
        guard !stale.isEmpty else { return }
        let briturn = stale.filter { isBriturn($0) }
        let tuya = stale.filter { !isBriturn($0) }
        Task { [weak self] in
            guard let self = self else { return }
            async let lights: Void = self.refreshBriturnStatuses(limitingTo: briturn, scope: "switch")
            await self.refreshTuyaStatuses(limitingTo: tuya, scope: "switch")
            await lights
        }
    }

    /// Fetches DPS for one device. Non-forced calls are cached until a rescan
    /// or poll forces a re-read; concurrent calls for the same id de-duplicate.
    public func loadStatus(for device: Device, force: Bool = false) async {
        // Briturn devices have no Tuya DPS surface; their status comes from
        // loadBriturnStatus instead. Requesting Tuya status only produces
        // error noise.
        guard !isBriturn(device), !isKEF(device), !isCast(device) else { return }
        guard device.hasAddress else { return }
        guard !statusLoading.contains(device.id), !statusInFlight.contains(device.id) else { return }
        if !force && loadedStatus.contains(device.id) { return }

        statusLoading.insert(device.id)
        statusInFlight.insert(device.id)
        defer {
            statusLoading.remove(device.id)
            statusInFlight.remove(device.id)
            lastStatusAt[device.id] = Date()
        }

        let readStartedAt = Date()
        switch await fetchStatus(for: device.id) {
        case .success(let decoded, let viaCloud):
            guard !readPredatesUserWrite(device.id, startedAt: readStartedAt) else { return }
            applyStatus(device.id, decoded: decoded, viaCloud: viaCloud)
        case .failure(let message):
            if statusErrors[device.id] != message { statusErrors[device.id] = message }
        }
    }

    // MARK: - Tuya

    /// Tuya DPS sweep over `devices` (default: the whole roster) through a
    /// sliding window: a new request starts the moment any slot frees, so an
    /// offline device idles only its own slot.
    func refreshTuyaStatuses(limitingTo devices: [Device]? = nil, scope: String) async {
        let ids = (devices ?? self.devices)
            .filter { $0.hasAddress && !isBriturn($0) && !isKEF($0) && !isCast($0) }
            .filter { !statusLoading.contains($0.id) && !statusInFlight.contains($0.id) }
            .map(\.id)
        guard !ids.isEmpty else { return }
        let started = Date()
        statusInFlight.formUnion(ids)
        defer { statusInFlight.subtract(ids) }

        var dpsBatch: [String: [String: DPSValue]] = [:]
        var viaBatch: [String: Bool] = [:]
        var errorBatch: [String: String] = [:]
        let width = Self.tuyaSweepWidth
        await withTaskGroup(of: (String, StatusFetch).self, returning: Void.self) { group in
            var next = 0
            while next < ids.count && next < width && !Task.isCancelled {
                let id = ids[next]
                next += 1
                group.addTask { (id, await self.fetchStatus(for: id)) }
            }
            while let pair = await group.next() {
                switch pair.1 {
                case .success(let decoded, let viaCloud):
                    dpsBatch[pair.0] = decoded
                    viaBatch[pair.0] = viaCloud
                case .failure(let message):
                    errorBatch[pair.0] = message
                }
                guard !Task.isCancelled, next < ids.count else { continue }
                let id = ids[next]
                next += 1
                group.addTask { (id, await self.fetchStatus(for: id)) }
            }
        }
        let finished = Date()
        for id in ids { lastStatusAt[id] = finished }
        applyPollBatch(dps: dpsBatch, viaCloud: viaBatch, errors: errorBatch, readStartedAt: started)
        logSweep(scope: "\(scope)-tuya", devices: ids.count, started: started,
                 detail: "ok=\(dpsBatch.count) failed=\(errorBatch.count) viaCloud=\(viaBatch.values.filter { $0 }.count)")
    }

    func fetchStatus(for id: String) async -> StatusFetch {
        do {
            let reply = try await bridge.request(["cmd": "status", "id": id], timeout: Self.statusRequestTimeout)
            guard reply["ok"] as? Bool == true else {
                return .failure(reply["error"] as? String ?? "Status failed.")
            }
            guard let raw = reply["dps"] else {
                return .failure("Device returned no dps.")
            }
            return .success(
                try Self.decodeDps(raw),
                viaCloud: Self.isRemoteVia(reply["via"])
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Single coalesced write for one sweep: each published collection is
    /// assigned at most once, and not at all when its contents are unchanged.
    func applyPollBatch(
        dps: [String: [String: DPSValue]],
        viaCloud: [String: Bool],
        errors: [String: String],
        readStartedAt: Date? = nil
    ) {
        // Reads that began before the user's latest command are stale by
        // construction: drop them rather than flash the old value.
        let dps = dps.filter { !readPredatesUserWrite($0.key, startedAt: readStartedAt) }
        let viaCloud = viaCloud.filter { dps[$0.key] != nil }
        guard !dps.isEmpty || !errors.isEmpty else { return }
        if !dps.isEmpty {
            // Reconcile BEFORE merging: the poll is a wire read like any other
            // and must not paint over a fresh user intent. The power bit is
            // derived from the reconciled map, not the raw decode, so dp1
            // follows the same rule as dp3 and every unseen dp.
            var nextDps = dpsById
            var nextOn = isOn
            for (id, decoded) in dps {
                let resolved = reconciled(id, decoded)
                nextDps[id] = resolved
                if let power = resolved["1"]?.boolValue { nextOn[id] = power }
            }
            if nextDps != dpsById { dpsById = nextDps }
            if nextOn != isOn { isOn = nextOn }
            let nextVia = statusViaCloud.merging(viaCloud) { _, new in new }
            if nextVia != statusViaCloud { statusViaCloud = nextVia }
            loadedStatus.formUnion(dps.keys)
        }
        var mergedErrors = statusErrors
        for id in dps.keys { mergedErrors[id] = nil }
        for (id, message) in errors { mergedErrors[id] = message }
        if mergedErrors != statusErrors { statusErrors = mergedErrors }
    }

    // MARK: - Briturn

    /// Briturn wire-state sweep. LAN probes (sliding window) run alongside the
    /// cloud read for lights that have no live LAN evidence; LAN results are
    /// painted BEFORE the cloud fallback for failed probes is awaited.
    func refreshBriturnStatuses(limitingTo devices: [Device]? = nil, scope: String = "poll") async {
        let now = Date()
        let candidates = (devices ?? self.devices).filter {
            isBriturn($0) && !$0.isBLE && !statusLoading.contains($0.id) && !statusInFlight.contains($0.id)
        }
        var lanTargets: [Device] = []
        var cloudDirect: [Device] = []
        var skippedIDs: [String] = []
        for device in candidates {
            let cloudBacked = briturnCloudDevices[device.id] != nil
            if cloudBacked && cloudOnline[device.id] == false && isBLELive(for: device) {
                // Cloud says offline AND a live Bluetooth peripheral exists:
                // the LAN address is stale (same rule as reachability) and the
                // cloud has no state — BLE adverts are the source.
                skippedIDs.append(device.id)
            } else if device.hasAddress && !(cloudBacked && lanBackedOff(device.id, now: now)) {
                lanTargets.append(device)
            } else if cloudBacked {
                cloudDirect.append(device)
            } else {
                skippedIDs.append(device.id)
            }
        }
        // No read path to try: count them as just-read so a dashboard switch
        // does not keep reporting (and re-scheduling) them as stale.
        for id in skippedIDs { lastStatusAt[id] = now }
        let skipped = skippedIDs.count
        guard !lanTargets.isEmpty || !cloudDirect.isEmpty else { return }
        let ids = lanTargets.map(\.id) + cloudDirect.map(\.id)
        let started = Date()
        statusInFlight.formUnion(ids)
        defer { statusInFlight.subtract(ids) }

        let cloudOnly = cloudDirect
        async let cloudFirst: Void = refreshBriturnCloudStatesIfAny(cloudOnly)
        let knownStates = briturnStatus
        let results = await Self.queryBriturnLAN(lanTargets, width: Self.briturnSweepWidth)

        var batch: [String: BriturnState] = [:]
        var failed: [Device] = []
        for device in lanTargets {
            if let state = results[device.id] {
                batch[device.id] = state
                noteLANResult(device.id, ok: true)
            } else {
                failed.append(device)
                noteLANResult(device.id, ok: false)
            }
        }
        applyBriturnWireStates(batch, readStartedAt: started)
        if !batch.isEmpty {
            var nextVia = statusViaCloud
            var nextErrors = statusErrors
            for id in batch.keys {
                nextVia[id] = false
                nextErrors[id] = nil
            }
            if nextVia != statusViaCloud { statusViaCloud = nextVia }
            if nextErrors != statusErrors { statusErrors = nextErrors }
        }
        await cloudFirst
        let fallback = failed.filter { briturnCloudDevices[$0.id] != nil }
        await refreshBriturnCloudStatesIfAny(fallback)
        // Poll timeouts on lights with a known state stay quiet; only lights
        // never seen (and not cloud-backed) alarm.
        var nextErrors = statusErrors
        for device in failed where knownStates[device.id] == nil
            && briturnStatus[device.id] == nil && briturnCloudDevices[device.id] == nil {
            nextErrors[device.id] = "Light unreachable."
        }
        if nextErrors != statusErrors { statusErrors = nextErrors }
        let finished = Date()
        for id in ids { lastStatusAt[id] = finished }
        logSweep(scope: "\(scope)-briturn", devices: ids.count, started: started,
                 detail: "lan=\(lanTargets.count) lanFailed=\(failed.count) cloud=\(cloudDirect.count + fallback.count) skipped=\(skipped)")
    }

    /// Bounded sliding window of direct LAN queries; no barrier between
    /// batches, so total time approaches the slowest single query.
    nonisolated static func queryBriturnLAN(_ targets: [Device], width: Int) async -> [String: BriturnState] {
        await withTaskGroup(of: (String, BriturnState?).self, returning: [String: BriturnState].self) { group in
            var next = 0
            while next < targets.count && next < width && !Task.isCancelled {
                let device = targets[next]
                next += 1
                group.addTask { (device.id, await FluxClient.query(ip: device.ip)) }
            }
            var collected: [String: BriturnState] = [:]
            while let (id, state) = await group.next() {
                if let state = state { collected[id] = state }
                guard !Task.isCancelled, next < targets.count else { continue }
                let device = targets[next]
                next += 1
                group.addTask { (device.id, await FluxClient.query(ip: device.ip)) }
            }
            return collected
        }
    }

    /// No live LAN evidence: repeated probe failures put a cloud-backed light
    /// on a timed back-off (status only — control routing is unchanged).
    func lanBackedOff(_ id: String, now: Date) -> Bool {
        guard let until = lanBackoffUntil[id] else { return false }
        return now < until
    }

    func noteLANResult(_ id: String, ok: Bool) {
        if ok {
            lanFailStreak[id] = nil
            lanBackoffUntil[id] = nil
            return
        }
        let streak = (lanFailStreak[id] ?? 0) + 1
        lanFailStreak[id] = streak
        if streak >= Self.lanFailStreakThreshold {
            lanBackoffUntil[id] = Date().addingTimeInterval(Self.lanBackoffInterval)
        }
    }

    private func refreshBriturnCloudStatesIfAny(_ devices: [Device]) async {
        guard !devices.isEmpty else { return }
        await refreshBriturnCloudStates(for: devices)
    }

    /// Cloud state for briturn lights, written as one compare-before-assign
    /// per published collection.
    func refreshBriturnCloudStates(for devices: [Device]) async {
        let mapped = devices.compactMap { briturnCloudDevices[$0.id] }
        var nextErrors = statusErrors
        defer { if nextErrors != statusErrors { statusErrors = nextErrors } }
        guard !mapped.isEmpty else {
            for device in devices { nextErrors[device.id] = "No local address or connected Briturn Cloud device." }
            return
        }
        do {
            let readStartedAt = Date()
            let states = try await briturnCloud.queryStates(devices: mapped)
            nextErrors = statusErrors   // re-base after the await
            var paint: [String: BriturnState] = [:]
            var nextVia = statusViaCloud
            var nextOnline = cloudOnline
            for device in mapped {
                let id = device.canonicalID
                if let state = states[id] {
                    paint[id] = state
                    nextVia[id] = true
                    nextErrors[id] = nil
                    nextOnline[id] = true
                } else {
                    nextOnline[id] = false
                    nextErrors[id] = device.supportsLighting ? "Light is offline in Briturn Cloud." : "Cloud controls for this model are not supported yet."
                }
            }
            applyBriturnWireStates(paint, readStartedAt: readStartedAt)
            if nextVia != statusViaCloud { statusViaCloud = nextVia }
            if nextOnline != cloudOnline { cloudOnline = nextOnline }
        } catch {
            nextErrors = statusErrors
            let message = (error as? BriturnCloudError)?.localizedDescription ?? "Could not read Briturn Cloud status."
            for device in mapped { nextErrors[device.canonicalID] = message }
            if briturnCloudError != message { briturnCloudError = message }
        }
    }

    private func logSweep(scope: String, devices: Int, started: Date, detail: String) {
        let tookMs = Int(Date().timeIntervalSince(started) * 1000)
        AppLog.store.notice("MyHome: status refresh scope=\(scope, privacy: .public) devices=\(devices, privacy: .public) took=\(tookMs, privacy: .public)ms \(detail, privacy: .public)")
    }
}

// KEF LS50 Wireless II in the DeviceStore: local records, one refresh path,
// ordered writes with readback. A KEF device never enters the Tuya/Briturn
// paths (its Device.ip is empty); every branch for it lives here.
import Foundation

public enum KEFWriteOutcome: Equatable {
    /// A readback shows the commanded value.
    case confirmed(KEFState)
    /// The speaker answered but still shows something else.
    case mismatch(KEFState)
    /// Accepted by HTTP, readback unavailable.
    case unconfirmed(String)
    /// A newer intent replaced this one before it was sent, or overtook it before its readback.
    case superseded
    case failed(KEFError)
}

public enum KEFFreshness: Equatable { case fresh, stale, never }

extension DeviceStore {
    // MARK: - Lookup

    public func isKEF(_ device: Device) -> Bool { device.category == KEFProtocol.category && device.id.hasPrefix(KEFProtocol.idPrefix) }
    public func kefRecord(for device: Device) -> KEFSpeakerRecord? { kef.records[device.id] }
    public var kefSpeakerDevices: [Device] { kef.devices }

    /// Last confirmed reading (may be stale — check `kefFreshness`).
    public func kefState(for device: Device) -> KEFState? {
        kef.readings[device.id].flatMap { $0.lastSuccess == nil ? nil : $0.state }
    }

    public func kefReading(for device: Device) -> KEFReading? { kef.readings[device.id] }

    /// Older than two visible refresh periods counts as stale.
    public func kefFreshness(for device: Device, now: Date = Date()) -> KEFFreshness {
        guard let last = kef.readings[device.id]?.lastSuccess else { return .never }
        return now.timeIntervalSince(last) > kef.config.visibleRefreshInterval * 2 ? .stale : .fresh
    }

    public func kefPower(for device: Device) -> Bool? {
        switch kefState(for: device)?.power {
        case .active?: return true
        case .standby?: return false
        default: return nil
        }
    }

    public var kefConfig: KEFConfig { kef.config }

    /// Highest volume the UI/commands may use for this speaker.
    public func kefVolumeCeiling(for device: Device) -> Int {
        min(kefState(for: device)?.maxVolume ?? kef.config.volumeRange.upperBound, kef.config.volumeRange.upperBound)
    }

    // MARK: - Records

    func loadKEFSpeakers() {
        for record in kef.persistence.load() { kef.records[record.id] = record }
        for id in kef.records.keys where kef.gates[id] == nil { kef.gates[id] = KEFSerialGate() }
    }

    /// Verified read-only identity check; unsupported models are refused.
    public func kefTestConnection(address: String) async throws -> KEFIdentity {
        let client = try kef.makeClient(address)
        let identity = try await client.fetchIdentity()
        guard identity.isSupportedModel else { throw KEFError.unsupportedModel(identity.model) }
        return identity
    }

    /// Adds or updates (same stable identity = endpoint update, name/room kept
    /// when the new values are empty).
    @discardableResult
    public func addKEFSpeaker(identity: KEFIdentity, address: String, name: String, room: String) -> KEFSpeakerRecord {
        let existing = kef.records[identity.deviceID]
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedRoom = room.trimmingCharacters(in: .whitespaces)
        let record = KEFSpeakerRecord(
            identity: identity, address: address,
            name: !trimmedName.isEmpty ? trimmedName : (existing?.name ?? identity.model),
            room: !trimmedRoom.isEmpty ? trimmedRoom : (existing?.room ?? ""))
        kef.records[record.id] = record
        if kef.gates[record.id] == nil { kef.gates[record.id] = KEFSerialGate() }
        kef.persistence.save(Array(kef.records.values))
        return record
    }

    public func updateKEFSpeaker(id: String, address: String? = nil, name: String? = nil, room: String? = nil) {
        guard var record = kef.records[id] else { return }
        if let address { record.address = address }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { record.name = name }
        if let room { record.room = room }
        kef.records[id] = record
        kef.persistence.save(Array(kef.records.values))
    }

    /// Removes only local configuration; the speaker itself is untouched.
    public func removeKEFSpeaker(id: String) {
        kef.records[id] = nil
        kef.readings[id] = nil
        kef.gates[id] = nil
        kef.volumeTokens[id] = nil
        kef.persistence.save(Array(kef.records.values))
    }

    // MARK: - Test seams

    func setKEFClientFactoryForTest(_ factory: @escaping (String) throws -> any KEFClientProtocol) { kef.makeClient = factory }
    func setKEFConfigForTest(_ config: KEFConfig) { kef.config = config }
    func applyKEFReadForTest(_ id: String, state: KEFState, generation: Int) { applyKEFRead(id, state: state, generation: generation) }
    func setKEFPersistenceForTest(_ store: KEFConfigurationStore) { kef.persistence = store }

    // MARK: - Refresh

    /// One poll step for every speaker, from the existing poll cycle (no second loop).
    func refreshKEFSpeakers() async {
        let now = Date()
        let due = kef.records.keys.sorted().filter { id in
            let interval = kef.visible.contains(id) ? kef.config.visibleRefreshInterval : kef.config.backgroundRefreshInterval
            guard let last = kef.readings[id]?.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= interval
        }
        await withTaskGroup(of: Void.self) { group in
            for id in due { group.addTask { await self.refreshKEF(id) } }
        }
    }

    public func setKEFVisible(_ devices: [Device]) {
        let ids = Set(devices.filter(isKEF).map(\.id))
        if kef.visible != ids { kef.visible = ids }
    }

    /// Reads one speaker. `manual` bypasses back-off once. Read-only transient
    /// failures retry once; a stale response never overwrites a newer write.
    @discardableResult
    public func refreshKEF(_ id: String, manual: Bool = false) async -> Bool {
        guard let record = kef.records[id] else { return false }
        var reading = kef.readings[id] ?? KEFReading()
        let now = Date()
        if !manual, let next = reading.nextAttempt, now < next { return false }
        guard reading.pending.isEmpty else { return false }
        reading.lastAttempt = now
        kef.readings[id] = reading
        let generation = reading.generation
        do {
            let state = try await readKEF(record)
            applyKEFRead(id, state: state, generation: generation)
            return true
        } catch {
            recordKEFFailure(id, error: error, generation: generation)
            return false
        }
    }

    private func readKEF(_ record: KEFSpeakerRecord) async throws -> KEFState {
        let client = try kef.makeClient(record.address)
        let gate = kef.gates[record.id] ?? KEFSerialGate()
        do {
            return try await gate.run { try await client.fetchState() }
        } catch let error as KEFError where error == .timeout || error == .unreachable {
            try? await Task.sleep(nanoseconds: UInt64(kef.config.readbackDelay * 1_000_000_000))
            return try await gate.run { try await client.fetchState() }
        }
    }

    private func applyKEFRead(_ id: String, state: KEFState, generation: Int) {
        guard var reading = kef.readings[id] else { return }
        reading.lastSuccess = Date()
        reading.lastError = nil
        reading.failures = 0
        reading.nextAttempt = nil
        // A read that began before a newer write is dropped (stale response).
        if reading.generation == generation {
            var merged = state
            if merged.maxVolume == nil { merged.maxVolume = reading.state.maxVolume }
            reading.state = merged
        }
        kef.readings[id] = reading
    }

    private func recordKEFFailure(_ id: String, error: Error, generation: Int) {
        guard var reading = kef.readings[id] else { return }
        reading.lastError = (error as? KEFError) ?? .malformedResponse
        reading.failures += 1
        reading.nextAttempt = Date().addingTimeInterval(kef.config.backoff(afterFailures: reading.failures))
        kef.readings[id] = reading
    }

    /// Fresh read for verification (bypasses back-off; published like any read).
    func readBackKEF(_ device: Device) async -> RawReading {
        guard let record = kef.records[device.id] else { return .unavailable("not a KEF speaker") }
        let generation = kef.readings[device.id]?.generation ?? 0
        do {
            let state = try await readKEF(record)
            applyKEFRead(device.id, state: state, generation: generation)
            return .kef(state)
        } catch {
            recordKEFFailure(device.id, error: error, generation: generation)
            return .unavailable((error as? KEFError)?.message ?? "no reading")
        }
    }

    // MARK: - Writes

    /// Sends one action, then performs ONE bounded readback. HTTP success alone
    /// never confirms; the requested value is never published before it is read.
    public func kefWrite(_ device: Device, _ action: KEFAction) async -> KEFWriteOutcome {
        let id = device.id
        guard let record = kef.records[id] else { return .failed(.unreachable) }
        var reading = kef.readings[id] ?? KEFReading()
        guard reading.lastSuccess != nil else { return .failed(.unreachable) }
        if action.requiresActive, reading.state.power != .active { return .failed(.standbyBlocksWrite) }
        if case .volume(let value) = action {
            let range = kef.config.volumeRange.lowerBound...kefVolumeCeiling(for: device)
            guard range.contains(value) else { return .failed(.volumeOutOfRange(range)) }
        }
        let client: any KEFClientProtocol
        do { client = try kef.makeClient(record.address) } catch { return .failed((error as? KEFError) ?? .invalidAddress) }
        let gate = kef.gates[id] ?? KEFSerialGate()

        var token = 0
        if case .volume = action { token = (kef.volumeTokens[id] ?? 0) + 1; kef.volumeTokens[id] = token }
        reading.generation += 1
        reading.pending.insert(action.control)
        kef.readings[id] = reading
        let generation = reading.generation
        defer { kef.readings[id]?.pending.remove(action.control) }

        let sent: Bool
        do {
            sent = try await gate.run { @MainActor [weak self] () throws -> Bool in
                if case .volume = action, self?.kef.volumeTokens[id] != token { return false }
                try await Self.performKEF(action, client: client)
                return true
            }
        } catch {
            let err = (error as? KEFError) ?? .malformedResponse
            kef.readings[id]?.lastError = err
            return .failed(err)
        }
        guard sent else { return .superseded }

        try? await Task.sleep(nanoseconds: UInt64(kef.config.readbackDelay * 1_000_000_000))
        // Power transitions are slow on this speaker: poll (bounded) until the readback matches.
        let isPower = action.control == .power
        let deadline = Date().addingTimeInterval(isPower ? kef.config.powerSettleTimeout : 0)
        do {
            var state = try await gate.run { try await client.fetchState() }
            while isPower, action.matches(state) != true, Date() < deadline, kef.readings[id]?.generation == generation {
                try? await Task.sleep(nanoseconds: UInt64(kef.config.powerSettleInterval * 1_000_000_000))
                state = try await gate.run { try await client.fetchState() }
            }
            applyKEFRead(id, state: state, generation: generation)
            // A newer write overtook this one: its readback speaks for the speaker, not ours.
            if kef.readings[id]?.generation != generation { return .superseded }
            return action.matches(state) == true ? .confirmed(state) : (action.matches(state) == nil ? .unconfirmed("the speaker did not report that value") : .mismatch(state))
        } catch {
            return .unconfirmed((error as? KEFError)?.message ?? "no readback")
        }
    }

    nonisolated private static func performKEF(_ action: KEFAction, client: any KEFClientProtocol) async throws {
        switch action {
        case .power(let on): try await client.setPower(on)
        case .volume(let value): try await client.setVolume(value)
        case .mute(let value): try await client.setMuted(value)
        case .input(let value): try await client.setInput(value)
        }
    }
}

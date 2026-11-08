// Cast speakers (Google Home / Nest Mini) in the DeviceStore: local records,
// one refresh path, ordered writes with readback. A Cast device never enters
// the Tuya/Briturn paths (its Device.ip is empty); every branch lives here.
import Foundation

public enum CastWriteOutcome: Equatable {
    case confirmed(CastState)
    case mismatch(CastState)
    case unconfirmed(String)
    case superseded
    case failed(CastError)
}

public enum CastFreshness: Equatable { case fresh, stale, never }

extension DeviceStore {
    // MARK: - Lookup

    public func isCast(_ device: Device) -> Bool { device.category == CastProtocol.category && device.id.hasPrefix(CastProtocol.idPrefix) }
    public func castRecord(for device: Device) -> CastSpeakerRecord? { cast.records[device.id] }
    public var castSpeakerDevices: [Device] { cast.devices }
    public var castConfig: CastConfig { cast.config }
    public func castReading(for device: Device) -> CastReading? { cast.readings[device.id] }

    public func castState(for device: Device) -> CastState? {
        cast.readings[device.id].flatMap { $0.lastSuccess == nil ? nil : $0.state }
    }

    public func castFreshness(for device: Device, now: Date = Date()) -> CastFreshness {
        guard let last = cast.readings[device.id]?.lastSuccess else { return .never }
        return now.timeIntervalSince(last) > cast.config.visibleRefreshInterval * 2 ? .stale : .fresh
    }

    // MARK: - Records

    func loadCastSpeakers() {
        for record in cast.persistence.load() { cast.records[record.id] = record }
        for id in cast.records.keys where cast.gates[id] == nil { cast.gates[id] = KEFSerialGate() }
    }

    /// Adds or updates (same stable device id = endpoint update; name/room kept when new values are empty).
    @discardableResult
    public func addCastSpeaker(_ incoming: CastSpeakerRecord) -> CastSpeakerRecord {
        var record = incoming
        if let existing = cast.records[incoming.id] {
            if record.name.trimmingCharacters(in: .whitespaces).isEmpty { record.name = existing.name }
            if record.room.trimmingCharacters(in: .whitespaces).isEmpty { record.room = existing.room }
        }
        cast.records[record.id] = record
        if cast.gates[record.id] == nil { cast.gates[record.id] = KEFSerialGate() }
        cast.persistence.save(Array(cast.records.values))
        return record
    }

    public func updateCastSpeaker(id: String, name: String? = nil, room: String? = nil) {
        guard var record = cast.records[id] else { return }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { record.name = name }
        if let room { record.room = room }
        cast.records[id] = record
        cast.persistence.save(Array(cast.records.values))
    }

    /// Removes only local configuration; the speaker itself is untouched.
    public func removeCastSpeaker(id: String) {
        cast.records[id] = nil
        cast.readings[id] = nil
        cast.gates[id] = nil
        cast.volumeTokens[id] = nil
        cast.persistence.save(Array(cast.records.values))
    }

    // MARK: - Radio presets

    public var castPresets: [CastRadioPreset] { cast.presets }
    public var castLastPlayed: String? { cast.radio.lastPlayed }

    @discardableResult
    public func addCastPreset(name: String, url: String, contentType: String = CastMediaSource.fallbackContentType) -> CastRadioPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let preset = CastRadioPreset(name: trimmed, url: url.trimmingCharacters(in: .whitespaces), contentType: contentType)
        guard !trimmed.isEmpty, preset.source != nil else { return nil }
        cast.presets.append(preset)
        cast.radio.save(cast.presets)
        return preset
    }

    public func removeCastPreset(id: String) {
        cast.presets.removeAll { $0.id == id }
        cast.radio.save(cast.presets)
    }

    /// Plays a preset (remembered as the target of a bare "play music").
    public func castPlay(_ device: Device, preset: CastRadioPreset) async -> CastWriteOutcome {
        guard let source = preset.source else { return .failed(.unplayableSource) }
        return await castWrite(device, .playMedia(source))
    }

    /// Resolves a spoken/typed station name against the saved presets.
    public func castPreset(matching spoken: String) -> CastRadioPreset? {
        CastRadioPreset.resolve(spoken, in: cast.presets, lastPlayed: cast.radio.lastPlayed)
    }

    // MARK: - Test seams

    func setCastClientFactoryForTest(_ factory: @escaping (CastSpeakerRecord) throws -> any CastClientProtocol) { cast.makeClient = factory }
    func setCastConfigForTest(_ config: CastConfig) { cast.config = config }
    func setCastPersistenceForTest(_ store: CastConfigurationStore) { cast.persistence = store }

    // MARK: - Refresh

    func refreshCastSpeakers() async {
        let now = Date()
        let due = cast.records.keys.sorted().filter { id in
            let interval = cast.visible.contains(id) ? cast.config.visibleRefreshInterval : cast.config.backgroundRefreshInterval
            guard let last = cast.readings[id]?.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= interval
        }
        await withTaskGroup(of: Void.self) { group in
            for id in due { group.addTask { await self.refreshCast(id) } }
        }
    }

    public func setCastVisible(_ devices: [Device]) {
        let ids = Set(devices.filter(isCast).map(\.id))
        if cast.visible != ids { cast.visible = ids }
    }

    @discardableResult
    public func refreshCast(_ id: String, manual: Bool = false) async -> Bool {
        guard let record = cast.records[id] else { return false }
        var reading = cast.readings[id] ?? CastReading()
        let now = Date()
        if !manual, let next = reading.nextAttempt, now < next { return false }
        guard reading.pending.isEmpty else { return false }
        reading.lastAttempt = now
        cast.readings[id] = reading
        let generation = reading.generation
        do {
            applyCastRead(id, state: try await readCast(record), generation: generation)
            return true
        } catch {
            recordCastFailure(id, error: error)
            return false
        }
    }

    private func readCast(_ record: CastSpeakerRecord) async throws -> CastState {
        let client = try cast.makeClient(record)
        let gate = cast.gates[record.id] ?? KEFSerialGate()
        return try await gate.run { try await client.fetchState() }
    }

    private func applyCastRead(_ id: String, state: CastState, generation: Int) {
        guard var reading = cast.readings[id] else { return }
        reading.lastSuccess = Date()
        reading.lastError = nil
        reading.failures = 0
        reading.nextAttempt = nil
        if reading.generation == generation { reading.state = state }
        cast.readings[id] = reading
    }

    private func recordCastFailure(_ id: String, error: Error) {
        guard var reading = cast.readings[id] else { return }
        reading.lastError = (error as? CastError) ?? .unreachable
        reading.failures += 1
        reading.nextAttempt = Date().addingTimeInterval(cast.config.backoff(afterFailures: reading.failures))
        cast.readings[id] = reading
    }

    func readBackCast(_ device: Device) async -> RawReading {
        guard let record = cast.records[device.id] else { return .unavailable("not a Cast speaker") }
        let generation = cast.readings[device.id]?.generation ?? 0
        do {
            let state = try await readCast(record)
            applyCastRead(device.id, state: state, generation: generation)
            return .cast(state)
        } catch {
            recordCastFailure(device.id, error: error)
            return .unavailable((error as? CastError)?.message ?? "no reading")
        }
    }

    // MARK: - Writes

    /// Sends one action, then ONE bounded readback; success of the send alone never confirms.
    public func castWrite(_ device: Device, _ action: CastAction) async -> CastWriteOutcome {
        let id = device.id
        guard let record = cast.records[id] else { return .failed(.unreachable) }
        if case .volume(let value) = action {
            let range = cast.config.volumeRange
            guard range.contains(value) else { return .failed(.volumeOutOfRange(range)) }
        }
        if case .playMedia(let source) = action, let preset = cast.presets.first(where: { $0.url == source.url.absoluteString }) {
            cast.radio.lastPlayed = preset.id
        }
        let client: any CastClientProtocol
        do { client = try cast.makeClient(record) } catch { return .failed((error as? CastError) ?? .invalidAddress) }
        let gate = cast.gates[id] ?? KEFSerialGate()

        var reading = cast.readings[id] ?? CastReading()
        var token = 0
        if case .volume = action { token = (cast.volumeTokens[id] ?? 0) + 1; cast.volumeTokens[id] = token }
        reading.generation += 1
        reading.pending.insert(action.control)
        cast.readings[id] = reading
        let generation = reading.generation
        defer { cast.readings[id]?.pending.remove(action.control) }

        let sent: Bool
        do {
            sent = try await gate.run { @MainActor [weak self] () throws -> Bool in
                if case .volume = action, self?.cast.volumeTokens[id] != token { return false }
                try await Self.performCast(action, client: client)
                return true
            }
        } catch {
            let err = (error as? CastError) ?? .unreachable
            cast.readings[id]?.lastError = err
            return .failed(err)
        }
        guard sent else { return .superseded }

        try? await Task.sleep(nanoseconds: UInt64(cast.config.readbackDelay * 1_000_000_000))
        // A started stream needs a few seconds to buffer: poll (bounded) until the readback matches.
        var isPlay = false
        if case .playMedia = action { isPlay = true }
        let deadline = Date().addingTimeInterval(isPlay ? cast.config.playSettleTimeout : 0)
        do {
            var state = try await gate.run { try await client.fetchState() }
            while isPlay, action.matches(state) != true, Date() < deadline, cast.readings[id]?.generation == generation {
                try? await Task.sleep(nanoseconds: UInt64(cast.config.playSettleInterval * 1_000_000_000))
                state = try await gate.run { try await client.fetchState() }
            }
            applyCastRead(id, state: state, generation: generation)
            if cast.readings[id]?.generation != generation { return .superseded }
            switch action.matches(state) {
            case .some(true): return .confirmed(state)
            case .some(false): return .mismatch(state)
            case .none: return .unconfirmed("the speaker did not report that value")
            }
        } catch {
            return .unconfirmed((error as? CastError)?.message ?? "no readback")
        }
    }

    nonisolated private static func performCast(_ action: CastAction, client: any CastClientProtocol) async throws {
        switch action {
        case .volume(let value): try await client.setVolume(value)
        case .mute(let value): try await client.setMuted(value)
        case .play, .pause, .stop: try await client.transport(action)
        case .playMedia(let source): try await client.play(source)
        }
    }
}

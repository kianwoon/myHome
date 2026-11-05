// Unified device-control API — the single entry point every interaction
// layer (dashboard, voice, Siri/Shortcuts, Foundation Models) goes through.
//
// Pipeline: resolve → policy (isControllable / reachability / capability) →
// PRE-CHECK (a stale or unknown target is read first) → one write per device
// over its own transport → POST-CHECK (the device is read back and compared
// with the intent) → structured CommandResult with a spoken summary.
//
// General rule: AN OUTCOME IS CONFIRMED ONLY ON POSITIVE EVIDENCE — a reply or
// read-back from the device showing the commanded value. A write with no
// read-back (Bluetooth, a cloud that did not answer) is "unverified", and one
// the device contradicts is "rejected"; nothing is painted into a success.
// Reads are bounded and per target; writes run sequentially — consumer
// firmware does not like bursts.
import Combine
import Foundation

/// Sendable snapshot of one device for intents, tools and summaries.
public struct DeviceSummary: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let room: String
    public let group: String?
    public let kind: DeviceKind
    public let capabilities: [SemanticCapability]
    public let reachability: ReachabilitySummary
    public let isControllable: Bool
    public let isOn: Bool?
    public let levelPercent: Int?

    public enum ReachabilitySummary: String, Codable, Hashable, Sendable {
        case wifi, cloud, bluetooth, offline
    }
}

public struct CommandRequest: Equatable {
    public var resolution: Resolution
    public var command: DeviceCommand
    public var origin: CommandOrigin
    /// The caller has already asked the user (or the user said "yes").
    public var confirmed: Bool

    public init(resolution: Resolution, command: DeviceCommand, origin: CommandOrigin, confirmed: Bool = false) {
        self.resolution = resolution
        self.command = command
        self.origin = origin
        self.confirmed = confirmed
    }
}

public enum OutcomeStatus: Equatable, Hashable, Sendable {
    /// The device itself reported the commanded value (reply echo or read-back).
    case confirmed
    /// The command was sent but nothing from the device confirms it yet (a
    /// Bluetooth send, a read-back that was not possible); the text says why.
    case unverified(String)
    /// Transport failed with an unknown outcome; the optimistic paint stays.
    case uncertain(String)
    /// The bridge or device rejected the write, or the read-back contradicts it.
    case rejected(String)
    /// Policy refused to send (offline, no control path).
    case denied(String)
    /// The device cannot perform this command.
    case unsupported(String)

    /// Only positive evidence counts as success.
    public var isSuccess: Bool {
        if case .confirmed = self { return true }
        return false
    }

    /// Sent and not contradicted (confirmed or unverified).
    public var wasSent: Bool {
        switch self {
        case .confirmed, .unverified: return true
        default: return false
        }
    }

    public var isUnverified: Bool {
        if case .unverified = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case .confirmed: return "confirmed"
        case .unverified(let text): return text.isEmpty ? "not yet confirmed by the device" : "not yet confirmed (\(text))"
        case .uncertain(let text), .rejected(let text), .denied(let text), .unsupported(let text):
            return text
        }
    }

    /// Short log/diagnostic word.
    public var label: String {
        switch self {
        case .confirmed: return "confirmed"
        case .unverified: return "unverified"
        case .uncertain: return "uncertain"
        case .rejected: return "rejected"
        case .denied: return "denied"
        case .unsupported: return "unsupported"
        }
    }
}

public struct DeviceOutcome: Identifiable, Equatable, Sendable {
    public let device: DeviceSummary
    public let status: OutcomeStatus
    public var id: String { device.id }

    public init(device: DeviceSummary, status: OutcomeStatus) {
        self.device = device
        self.status = status
    }
}

public struct CommandResult: Equatable {
    public enum Disposition: Equatable {
        case executed
        case needsConfirmation(deviceCount: Int)
        case ambiguous([DeviceSummary])
        case nothingToDo(String)
    }

    public let disposition: Disposition
    public let command: DeviceCommand
    public let scope: ResolutionScope?
    public let outcomes: [DeviceOutcome]
    /// Re-issue this (with `confirmed = true`) after the user agrees.
    public let pendingRequest: CommandRequest?
    public var spokenSummary: String { CommandPhrasing.summary(for: self) }

    /// Every target confirmed by the device.
    public var succeeded: Bool {
        if case .executed = disposition { return !outcomes.isEmpty && outcomes.allSatisfy { $0.status.isSuccess } }
        return false
    }
}

public enum PolicyDecision: Equatable {
    case allowed(CapabilityMap.WritePlan)
    case denied(OutcomeStatus)

    public var deniedStatus: OutcomeStatus? {
        if case .denied(let status) = self { return status }
        return nil
    }
}

@MainActor
public final class DeviceController: ObservableObject {
    public let store: DeviceStore
    public var config: ControlConfig
    public var resolverConfig: ResolverConfig
    public var vocabulary: ResolverVocabulary

    public init(store: DeviceStore, config: ControlConfig = .fromDefaults(),
                resolverConfig: ResolverConfig = .fromDefaults(), vocabulary: ResolverVocabulary = .standard) {
        self.store = store
        self.config = config
        self.resolverConfig = resolverConfig
        self.vocabulary = vocabulary
    }

    // MARK: - Registry

    public var devices: [Device] { store.devices }

    public func device(id: String) -> Device? {
        store.devices.first { $0.id == id }
    }

    public func profile(for device: Device) -> DeviceProfile {
        DeviceProfile(device: device, state: store.state(for: device), isBriturn: store.isBriturn(device))
    }

    public func supports(_ device: Device, _ capability: SemanticCapability) -> Bool {
        CapabilityMap.supported(for: profile(for: device)).contains(capability)
    }

    public func summary(for device: Device) -> DeviceSummary {
        let profile = profile(for: device)
        let reachability: DeviceSummary.ReachabilitySummary
        switch store.reachability(for: device) {
        case .wifi: reachability = .wifi
        case .cloud: reachability = .cloud
        case .bluetooth: reachability = .bluetooth
        case .offline: reachability = .offline
        }
        return DeviceSummary(
            id: device.id, name: device.name, room: device.room, group: device.group, kind: device.kind,
            capabilities: CapabilityMap.supported(for: profile).sorted { $0.rawValue < $1.rawValue },
            reachability: reachability,
            isControllable: store.isControllable(for: device),
            isOn: store.power(for: device),
            levelPercent: CapabilityMap.levelPercent(profile, briturn: store.briturnStatus[device.id])
        )
    }

    public func summaries() -> [DeviceSummary] {
        store.devices.map(summary(for:))
    }

    // MARK: - Resolution

    public func resolver(requiring capability: SemanticCapability? = nil) -> DeviceResolver {
        DeviceResolver(devices: store.devices, config: resolverConfig, vocabulary: vocabulary,
                       supports: { [weak self] device, capability in self?.supports(device, capability) ?? false },
                       isControllable: { [weak self] device in self?.store.isControllable(for: device) ?? false })
    }

    public func resolve(_ query: DeviceQuery) -> Resolution {
        resolver().resolve(query)
    }

    // MARK: - Policy

    public func check(_ command: DeviceCommand, on device: Device) -> PolicyDecision {
        guard store.isControllable(for: device) else {
            return .denied(.denied("has no control path (no address, Bluetooth or cloud)"))
        }
        // Reachability is authoritative for Briturn lights (live LAN / cloud /
        // Bluetooth facts). For Tuya devices it only echoes the last scan and
        // cloud poll, and the bridge still has a cloud fallback — so, like the
        // dashboard, the write is attempted and its real outcome reported.
        if store.isBriturn(device), store.reachability(for: device) == .offline {
            return .denied(.denied("is offline (no live WiFi, cloud or Bluetooth path)"))
        }
        switch CapabilityMap.plan(command, for: profile(for: device)) {
        case .success(let plan):
            return .allowed(plan)
        case .failure(let rejection):
            return .denied(.unsupported(Self.describe(rejection)))
        }
    }

    static func describe(_ rejection: CapabilityMap.Rejection) -> String {
        switch rejection {
        case .unsupported(let capability): return "does not support \(capability.rawValue)"
        case .needsStatus(let capability): return "needs a status read before \(capability.rawValue) can be set"
        case .outOfRange(let capability, let lower, let upper): return "\(capability.rawValue) must be \(lower)…\(upper)"
        case .unknownMode(let mode, let options):
            return options.isEmpty ? "has no mode \(mode)" : "has no mode \(mode) (options: \(options.joined(separator: ", ")))"
        }
    }

    // MARK: - Execution

    /// Resolve + perform in one call for callers that start from a query.
    public func perform(_ command: DeviceCommand, on query: DeviceQuery, origin: CommandOrigin, confirmed: Bool = false) async -> CommandResult {
        var scoped = query
        scoped.preferControllable = true
        if scoped.requiredCapability == nil { scoped.requiredCapability = command.capability }
        var (resolution, dropped) = resolver().resolveReporting(scoped)
        if case .none = resolution, scoped.requiredCapability != nil {
            // Nothing supports the command: resolve without the capability
            // filter so the reply can say WHY ("Kitchen Plug does not support level").
            scoped.requiredCapability = nil
            (resolution, dropped) = resolver().resolveReporting(scoped)
        }
        let names = resolution.devices.prefix(6).map(\.name).joined(separator: ", ")
        AppLog.assistant.info("perform query=\(scoped.text ?? "-", privacy: .public) kind=\(scoped.kind?.rawValue ?? "-", privacy: .public) room=\(scoped.room ?? "-", privacy: .public) capability=\(scoped.requiredCapability?.rawValue ?? "-", privacy: .public) resolution=\(Self.resolutionName(resolution), privacy: .public) devices=\(names, privacy: .public) dropped=\(dropped.count, privacy: .public)")
        let result = await perform(CommandRequest(resolution: resolution, command: command, origin: origin, confirmed: confirmed))
        guard !dropped.isEmpty else { return result }
        // A namesake with no control path is reported, never dropped in silence.
        let denials = dropped.map { DeviceOutcome(device: summary(for: $0), status: check(command, on: $0).deniedStatus ?? .denied("has no control path")) }
        switch result.disposition {
        case .executed:
            return CommandResult(disposition: .executed, command: command, scope: result.scope, outcomes: result.outcomes + denials, pendingRequest: nil)
        case .nothingToDo:
            return CommandResult(disposition: .executed, command: command, scope: nil, outcomes: denials, pendingRequest: nil)
        case .ambiguous:
            return CommandResult(disposition: result.disposition, command: command, scope: nil, outcomes: denials, pendingRequest: nil)
        case .needsConfirmation:
            return result
        }
    }

    private static func resolutionName(_ resolution: Resolution) -> String {
        switch resolution {
        case .none: return "none"
        case .single: return "single"
        case .set(let devices, _): return "set(\(devices.count))"
        case .briturnGroup(_, let members): return "briturnGroup(\(members.count))"
        case .ambiguous(let devices): return "ambiguous(\(devices.count))"
        }
    }

    public func perform(_ request: CommandRequest) async -> CommandResult {
        let command = request.command
        switch request.resolution {
        case .none:
            return CommandResult(disposition: .nothingToDo("No device matches that request."), command: command,
                                 scope: nil, outcomes: [], pendingRequest: nil)
        case .ambiguous(let candidates):
            return CommandResult(disposition: .ambiguous(candidates.map(summary(for:))), command: command,
                                 scope: nil, outcomes: [], pendingRequest: nil)
        case .single, .set, .briturnGroup:
            break
        }

        let targets = request.resolution.devices
        let decisions = targets.map { ($0, check(command, on: $0)) }
        let allowedCount = decisions.filter { if case .allowed = $0.1 { return true }; return false }.count
        let scope = Self.scope(of: request.resolution)

        if allowedCount == 0 {
            let outcomes = decisions.map { device, decision -> DeviceOutcome in
                if case .denied(let status) = decision { return DeviceOutcome(device: summary(for: device), status: status) }
                return DeviceOutcome(device: summary(for: device), status: .unverified("not attempted"))
            }
            return CommandResult(disposition: .executed, command: command, scope: scope, outcomes: outcomes, pendingRequest: nil)
        }

        if allowedCount >= config.confirmationDeviceThreshold, !request.confirmed {
            let pending = decisions.map { device, _ in DeviceOutcome(device: summary(for: device), status: .unverified("waiting for confirmation")) }
            var confirmedRequest = request
            confirmedRequest.confirmed = true
            return CommandResult(disposition: .needsConfirmation(deviceCount: allowedCount), command: command,
                                 scope: scope, outcomes: pending, pendingRequest: confirmedRequest)
        }

        AppLog.control.notice("MyHome: command \(String(describing: command), privacy: .public) origin=\(request.origin.rawValue, privacy: .public) targets=\(targets.count, privacy: .public)")

        // One write per device over its own transport: a group write can drop
        // a member (no address, Bluetooth-only) without a word; this cannot.
        var outcomes: [DeviceOutcome] = []
        for (device, decision) in decisions {
            switch decision {
            case .denied(let status):
                AppLog.control.notice("MyHome: verify pre id=\(device.id, privacy: .public) name=\(device.name, privacy: .public) refused=\(status.reason, privacy: .public)")
                outcomes.append(DeviceOutcome(device: summary(for: device), status: status))
            case .allowed(let plan):
                await precheck(device)
                let status = await execute(plan, on: device)
                outcomes.append(DeviceOutcome(device: summary(for: device), status: status))
            }
        }
        return CommandResult(disposition: .executed, command: command, scope: scope, outcomes: outcomes, pendingRequest: nil)
    }

    static func scope(of resolution: Resolution) -> ResolutionScope? {
        switch resolution {
        case .set(_, let scope): return scope
        case .briturnGroup(let group, _): return .group(group)
        default: return nil
        }
    }

    // MARK: - Pre-check

    /// A target whose reading is missing or older than the freshness window
    /// is read first (bounded), so the write starts from the real condition.
    private func precheck(_ device: Device) async {
        let stale = store.isStale(device, maxAge: config.stateFreshness)
        let reach = store.reachability(for: device)
        var via = "cached"
        if stale {
            let store = self.store
            let reading = await Deadline.run(seconds: config.verifyTimeout) { @MainActor in await store.readBack(device) }
            via = reading?.via ?? "timeout"
        }
        let state = CommandPhrasing.describe(summary(for: device))
        AppLog.control.notice("MyHome: verify pre id=\(device.id, privacy: .public) name=\(device.name, privacy: .public) reach=\("\(reach)", privacy: .public) stale=\(stale, privacy: .public) via=\(via, privacy: .public) state=\(state, privacy: .public)")
    }

    // MARK: - Execution

    private func execute(_ plan: CapabilityMap.WritePlan, on device: Device) async -> OutcomeStatus {
        let expectation = CapabilityMap.expectation(for: plan)
        let started = Date()
        switch plan {
        case .tuya(let dpId, let value):
            // Discrete values are painted optimistically, exactly like the
            // dashboard's toggles/pickers; continuous values rely on the
            // confirmed reply, like its sliders.
            let optimistic: [String: DPSValue] = Self.isDiscrete(value) ? [dpId: value] : [:]
            let ok = await store.setDps(device, [dpId: Self.raw(value)], optimistic: optimistic)
            let message = store.errorText ?? "set failed"
            // The device's own reply (dps echo) is positive evidence.
            if ok, let reply = store.lastSetReply[device.id], reply.at >= started,
               let current = reply.dps[dpId], Self.equivalent(current, value) {
                return finish(device, expectation: expectation, result: .confirmed, evidence: "reply dps \(dpId)=\(current)")
            }
            let verified = await verifyByReadBack(expectation, device: device, since: started)
            if ok || verified.isSuccess { return verified }
            if case .rejected = verified { return verified }
            // The write errored and nothing could be read back: a definite
            // rejection is reported as such, a transport error stays unknown.
            if store.lastSetRejected.contains(device.id) { return finish(device, expectation: expectation, result: .rejected(message), evidence: "bridge rejected") }
            return finish(device, expectation: expectation, result: .uncertain(message), evidence: "transport error, no read-back")
        case .briturn(let on, let color, let brightness, let cct):
            let ack = await store.setBriturn(device, on: on, color: color?.tuple, brightness: brightness, cct: cct)
            switch ack {
            case .failed(let message):
                return finish(device, expectation: expectation, result: .rejected(message), evidence: "write failed")
            case .applied(let readback):
                if let readback, case .match = compare(expectation, to: .briturn(readback, via: .wifi), since: started, device: device) {
                    return finish(device, expectation: expectation, result: .confirmed, evidence: "bridge readback")
                }
                return await verifyByReadBack(expectation, device: device, since: started)
            case .sent:
                return await verifyByReadBack(expectation, device: device, since: started)
            }
        }
    }

    // MARK: - Post-check

    enum Comparison: Equatable {
        case match
        case mismatch(String)
        /// Nothing can confirm this kind of write (CCT, brightness over Bluetooth).
        case unverifiable(String)
        case unavailable(String)
    }

    /// Reads the device back until it shows the commanded value or the verify
    /// window closes. Confirmed only on a matching read; rejected when the
    /// device still reports something else; unverified when it could not be
    /// read (and says why).
    func verifyByReadBack(_ expectation: CapabilityMap.Expectation, device: Device, since started: Date) async -> OutcomeStatus {
        let deadline = started.addingTimeInterval(config.verifyTimeout)
        var lastMismatch: String?
        var lastProblem = "no reading"
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let store = self.store
            guard let reading = await Deadline.run(seconds: remaining, { @MainActor in await store.readBack(device) }) else {
                lastProblem = "the read-back timed out"
                break
            }
            switch compare(expectation, to: reading, since: started, device: device) {
            case .match:
                return finish(device, expectation: expectation, result: .confirmed, evidence: "read-back via \(reading.via)")
            case .mismatch(let text):
                lastMismatch = text
            case .unverifiable(let text):
                return finish(device, expectation: expectation, result: .unverified(text), evidence: "read-back via \(reading.via)")
            case .unavailable(let text):
                lastProblem = text
            }
            try? await Task.sleep(nanoseconds: UInt64(config.settleInterval * 1_000_000_000))
        }
        if let lastMismatch {
            return finish(device, expectation: expectation, result: .rejected("the device still reports \(lastMismatch) after \(Int(config.verifyTimeout.rounded()))s"), evidence: "read-back")
        }
        return finish(device, expectation: expectation, result: .unverified(lastProblem), evidence: "no read-back")
    }

    private func finish(_ device: Device, expectation: CapabilityMap.Expectation, result: OutcomeStatus, evidence: String) -> OutcomeStatus {
        AppLog.control.notice("MyHome: verify post id=\(device.id, privacy: .public) name=\(device.name, privacy: .public) expect=\(String(describing: expectation), privacy: .public) evidence=\(evidence, privacy: .public) result=\(result.label, privacy: .public) reason=\(result.reason, privacy: .public)")
        return result
    }

    func compare(_ expectation: CapabilityMap.Expectation, to reading: DeviceStore.RawReading, since started: Date, device: Device) -> Comparison {
        switch (expectation, reading) {
        case (_, .unavailable(let text)):
            return .unavailable(text)
        case (.dps(let dpId, let value), .tuya(let dps, _)):
            guard let current = dps[dpId] else { return .unavailable("the status carries no dp \(dpId)") }
            return Self.equivalent(current, value) ? .match : .mismatch("dp \(dpId) = \(current)")
        case (.dps, .briturn):
            return .unavailable("a Tuya expectation against a Briturn reading")
        case (_, .tuya):
            return .unavailable("a Briturn expectation against a Tuya reading")
        case (.briturnPower(let on), .briturn(let state, let via)):
            if via == .bluetooth {
                // Only an advert heard AFTER the command is evidence; a cached
                // state with no timestamp proves nothing.
                guard let heard = store.lastBLEAdvert(for: device) else { return .unavailable("no Bluetooth advert timestamp") }
                guard heard >= started else { return .unavailable("no Bluetooth advert since the command") }
            }
            return state.on == on ? .match : .mismatch(state.on ? "on" : "off")
        case (.briturnBrightness(let percent), .briturn(let state, let via)):
            if via == .bluetooth { return .unverifiable("sent over Bluetooth; adverts cannot confirm brightness") }
            let level = CapabilityMap.briturnLevelPercent(state)
            return abs(level - percent) <= config.levelTolerance ? .match : .mismatch("\(level)%")
        case (.briturnColor(let rgb), .briturn(let state, let via)):
            if via == .bluetooth { return .unverifiable("sent over Bluetooth; adverts cannot confirm colour") }
            let close = abs(state.r - rgb.red) <= config.levelTolerance && abs(state.g - rgb.green) <= config.levelTolerance && abs(state.b - rgb.blue) <= config.levelTolerance
            return close ? .match : .mismatch("colour \(state.r),\(state.g),\(state.b)")
        case (.briturnColorTemperature, .briturn):
            return .unverifiable("colour temperature cannot be read back")
        case (.accepted, .briturn):
            return .unverifiable("nothing to compare")
        }
    }

    // MARK: - Helpers

    static func equivalent(_ lhs: DPSValue, _ rhs: DPSValue) -> Bool {
        if lhs == rhs { return true }
        if let l = lhs.doubleValue, let r = rhs.doubleValue { return l == r }
        if let l = lhs.stringValue, let r = rhs.stringValue { return l.caseInsensitiveCompare(r) == .orderedSame }
        return false
    }

    static func isDiscrete(_ value: DPSValue) -> Bool {
        switch value {
        case .bool, .string: return true
        default: return false
        }
    }

    /// JSON-ready payload value: integral numbers go as Int (what the bridge
    /// and the dashboard send for integer dps).
    static func raw(_ value: DPSValue) -> Any {
        switch value {
        case .bool(let bool): return bool
        case .number(let number): return number == number.rounded() ? Int(number) : number
        case .string(let string): return string
        case .array(let items): return items.map(raw)
        case .object(let dict): return dict.mapValues(raw)
        case .null: return NSNull()
        }
    }
}

/// One-shot wait on the store's publisher. `objectWillChange` fires before a
/// mutation, so each check is deferred to the next main-queue turn.
@MainActor
final class StateWaiter {
    private let store: DeviceStore
    private var cancellable: AnyCancellable?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(store: DeviceStore) {
        self.store = store
    }

    func wait(until predicate: @escaping @MainActor () -> Bool, timeout: TimeInterval) async -> Bool {
        if predicate() { return true }
        guard timeout > 0 else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            cancellable = store.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.continuation != nil else { return }
                    if predicate() { self.finish(true) }
                }
            }
            timer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(false)
            }
        }
    }

    private func finish(_ result: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        cancellable?.cancel()
        cancellable = nil
        timer?.cancel()
        timer = nil
        continuation.resume(returning: result)
    }
}

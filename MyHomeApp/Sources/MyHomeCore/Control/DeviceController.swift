// Unified device-control API — the single entry point every interaction
// layer (dashboard, voice, Siri/Shortcuts, Foundation Models) goes through.
//
// Pipeline: resolve → policy (isControllable / reachability / capability) →
// execute through DeviceStore's existing write paths → verify against the
// store's PUBLISHED state → structured CommandResult with a spoken summary.
//
// General rule: NO NEW DEVICE POLLING. Verification only observes what the
// store already publishes (set replies, the poll loop, BLE adverts); it never
// asks a device for its state. Writes run sequentially — the UI never fans
// out either, and consumer firmware does not like bursts.
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
    /// Store reported success and the published state shows the value.
    case confirmed
    /// Store reported success; the published state does not (yet) show the
    /// value (a continuous write whose reply carried no dps) — the store's
    /// own poll loop settles it.
    case unverified
    /// Transport failed with an unknown outcome; the optimistic paint stays.
    case uncertain(String)
    /// The bridge or device rejected the write; state was reverted.
    case rejected(String)
    /// Policy refused to send (offline, no control path).
    case denied(String)
    /// The device cannot perform this command.
    case unsupported(String)

    public var isSuccess: Bool {
        switch self {
        case .confirmed, .unverified: return true
        default: return false
        }
    }

    public var reason: String {
        switch self {
        case .confirmed: return "confirmed"
        case .unverified: return "not yet confirmed"
        case .uncertain(let text), .rejected(let text), .denied(let text), .unsupported(let text):
            return text
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

    public var succeeded: Bool {
        if case .executed = disposition { return outcomes.allSatisfy { $0.status.isSuccess } }
        return false
    }
}

public enum PolicyDecision: Equatable {
    case allowed(CapabilityMap.WritePlan)
    case denied(OutcomeStatus)
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
                       supports: { [weak self] device, capability in self?.supports(device, capability) ?? false })
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
        if scoped.requiredCapability == nil { scoped.requiredCapability = command.capability }
        var resolution = resolve(scoped)
        if case .none = resolution, scoped.requiredCapability != nil {
            // Nothing supports the command: resolve without the capability
            // filter so the reply can say WHY ("Kitchen Plug does not support level").
            scoped.requiredCapability = nil
            resolution = resolve(scoped)
        }
        return await perform(CommandRequest(resolution: resolution, command: command, origin: origin, confirmed: confirmed))
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
                return DeviceOutcome(device: summary(for: device), status: .unverified)
            }
            return CommandResult(disposition: .executed, command: command, scope: scope, outcomes: outcomes, pendingRequest: nil)
        }

        if allowedCount >= config.confirmationDeviceThreshold, !request.confirmed {
            let pending = decisions.map { device, _ in DeviceOutcome(device: summary(for: device), status: .unverified) }
            var confirmedRequest = request
            confirmedRequest.confirmed = true
            return CommandResult(disposition: .needsConfirmation(deviceCount: allowedCount), command: command,
                                 scope: scope, outcomes: pending, pendingRequest: confirmedRequest)
        }

        AppLog.control.notice("MyHome: command \(String(describing: command), privacy: .public) origin=\(request.origin.rawValue, privacy: .public) targets=\(targets.count, privacy: .public)")

        var outcomes: [DeviceOutcome] = []
        if case .briturnGroup(let group, let members) = request.resolution,
           let plan = decisions.lazy.compactMap({ decision -> CapabilityMap.WritePlan? in
               if case .allowed(let plan) = decision.1 { return plan }
               return nil
           }).first, case .briturn(let on, let color, let brightness, let cct) = plan {
            // The group write is the proven transport for Briturn groups
            // (cloud batch + BLE fallback + bridge group command).
            await store.setBriturnGroupState(group, on: on, color: color?.tuple, brightness: brightness, cct: cct)
            let groupError = store.errorText
            let denials = decisions.reduce(into: [String: OutcomeStatus]()) { map, entry in
                if case .denied(let status) = entry.1 { map[entry.0.id] = status }
            }
            for member in members {
                // Policy-refused members (offline, unsupported) keep their
                // denial and are never waited on: nothing was expected of them.
                if let denied = denials[member.id] {
                    outcomes.append(DeviceOutcome(device: summary(for: member), status: denied))
                    continue
                }
                outcomes.append(DeviceOutcome(device: summary(for: member),
                                              status: await briturnOutcome(member, expectation: CapabilityMap.expectation(for: plan), fallbackError: groupError)))
            }
        } else {
            for (device, decision) in decisions {
                switch decision {
                case .denied(let status):
                    outcomes.append(DeviceOutcome(device: summary(for: device), status: status))
                case .allowed(let plan):
                    let status = await execute(plan, on: device)
                    outcomes.append(DeviceOutcome(device: summary(for: device), status: status))
                }
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

    private func execute(_ plan: CapabilityMap.WritePlan, on device: Device) async -> OutcomeStatus {
        let expectation = CapabilityMap.expectation(for: plan)
        switch plan {
        case .tuya(let dpId, let value):
            // Discrete values are painted optimistically, exactly like the
            // dashboard's toggles/pickers; continuous values rely on the
            // confirmed reply, like its sliders.
            let optimistic: [String: DPSValue] = Self.isDiscrete(value) ? [dpId: value] : [:]
            let ok = await store.setDps(device, [dpId: Self.raw(value)], optimistic: optimistic)
            let message = store.errorText ?? "set failed"
            let matched = await waitForState(expectation, device: device)
            switch (ok, matched) {
            case (true, true): return .confirmed
            case (true, false): return .unverified
            case (false, true): return .uncertain(message)
            case (false, false): return .rejected(message)
            }
        case .briturn(let on, let color, let brightness, let cct):
            await store.setBriturn(device, on: on, color: color?.tuple, brightness: brightness, cct: cct)
            return await briturnOutcome(device, expectation: expectation, fallbackError: nil)
        }
    }

    private func briturnOutcome(_ device: Device, expectation: CapabilityMap.Expectation, fallbackError: String?) async -> OutcomeStatus {
        let error = store.statusErrors[device.id] ?? fallbackError
        let matched = await waitForState(expectation, device: device)
        switch (error, matched) {
        case (nil, true): return .confirmed
        case (nil, false): return .unverified
        case (let message?, true): return .uncertain(message)
        case (let message?, false): return .rejected(message)
        }
    }

    // MARK: - Verification

    /// True once the store's published state satisfies the expectation, or
    /// false after `config.verifyTimeout`. Observes `objectWillChange` only.
    func waitForState(_ expectation: CapabilityMap.Expectation, device: Device) async -> Bool {
        let store = self.store
        let predicate: @MainActor () -> Bool = {
            switch expectation {
            case .accepted:
                return store.statusErrors[device.id] == nil
            case .briturnPower(let on):
                return store.briturnStatus[device.id]?.on == on
            case .dps(let dpId, let value):
                guard let current = store.dps(for: device)[dpId] else { return false }
                return Self.equivalent(current, value)
            }
        }
        return await StateWaiter(store: store).wait(until: predicate, timeout: config.verifyTimeout)
    }

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

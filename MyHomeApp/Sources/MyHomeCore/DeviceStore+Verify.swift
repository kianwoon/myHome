// What a write really did, and how to read a device back afterwards. The
// store's published state is intent-defended (a lagging read never bounces a
// freshly painted value), which is right for the dashboard but not for
// verification: the controller needs the device's own answer. `WriteAck` is
// what each write path returns; `readBack` is a raw read over the transport
// the light is reachable by, painted authoritatively (after a write the
// wire is the truth, and a contradicting read must correct the paint).
import Foundation

extension DeviceStore {
    /// The honest result of one write on one device.
    public enum WriteAck: Equatable {
        /// The transport accepted it; `readback` is the device's state as the
        /// bridge/cloud read it back right after (nil when it did not read).
        case applied(readback: BriturnState?)
        /// Fire-and-forget (Bluetooth): nothing confirms it until an advert does.
        case sent
        case failed(String)
    }

    /// A reading straight from the device, not filtered by the intent window.
    public enum RawReading: Equatable {
        case briturn(BriturnState, via: Reachability)
        case tuya([String: DPSValue], viaCloud: Bool)
        case kef(KEFState)
        case unavailable(String)

        public var via: String {
            switch self {
            case .briturn(_, let via): return "\(via)"
            case .tuya(_, let viaCloud): return viaCloud ? "cloud" : "lan"
            case .kef: return "lan"
            case .unavailable: return "none"
            }
        }
    }

    /// When the device was last read (poll, sweep or read-back); nil = never.
    public func lastReadAt(_ id: String) -> Date? { lastStatusAt[id] }

    /// True when no reading exists or the last one is older than `maxAge`.
    public func isStale(_ device: Device, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        if isKEF(device) {
            guard let last = kef.readings[device.id]?.lastSuccess else { return true }
            return now.timeIntervalSince(last) > maxAge
        }
        if isBriturn(device) {
            if briturnStatus[device.id] == nil { return true }
        } else if device.hasAddress, dpsById[device.id] == nil {
            return true
        }
        guard let last = lastStatusAt[device.id] else { return true }
        return now.timeIntervalSince(last) > maxAge
    }

    /// Re-reads every stale device through the normal sweeps (bounded by the
    /// caller); the usual intent-aware paint applies, this is for snapshots.
    public func refreshStale(_ devices: [Device], maxAge: TimeInterval) async {
        let now = Date()
        let stale = devices.filter { isStale($0, maxAge: maxAge, now: now) }
        guard !stale.isEmpty else { return }
        let briturn = stale.filter { isBriturn($0) }
        let tuya = stale.filter { !isBriturn($0) && !isKEF($0) && $0.hasAddress }
        for speaker in stale where isKEF(speaker) { await refreshKEF(speaker.id, manual: true) }
        async let lights: Void = refreshBriturnStatuses(limitingTo: briturn, scope: "freshen")
        await refreshTuyaStatuses(limitingTo: tuya, scope: "freshen")
        await lights
    }

    /// Reads the device now over the path it is reachable by.
    public func readBack(_ device: Device) async -> RawReading {
        if isBriturn(device) { return await readBackBriturn(device) }
        if isKEF(device) { return await readBackKEF(device) }
        guard device.hasAddress else { return .unavailable("no address") }
        let started = Date()
        switch await fetchStatus(for: device.id) {
        case .success(let decoded, let viaCloud):
            lastStatusAt[device.id] = Date()
            if !readPredatesUserWrite(device.id, startedAt: started) {
                applyStatus(device.id, decoded: decoded, viaCloud: viaCloud)
            }
            return .tuya(decoded, viaCloud: viaCloud)
        case .failure(let message):
            return .unavailable(message)
        }
    }

    private func readBackBriturn(_ device: Device) async -> RawReading {
        let reach = reachability(for: device)
        if reach == .wifi, device.hasAddress, !device.isBLE {
            let state: BriturnState?
            if let hook = briturnLANReadHook {
                state = await hook(device)
            } else if Self.isUnderXCTest {
                state = nil   // never a real socket from the test host
            } else {
                state = await FluxClient.query(ip: device.ip)
            }
            if let state {
                lastStatusAt[device.id] = Date()
                applyBriturnWireState(device.id, state, authoritative: true)
                if statusViaCloud[device.id] != false { statusViaCloud[device.id] = false }
                return .briturn(state, via: .wifi)
            }
        }
        if let key = bleKey(for: device), isBLEKeyLive(key) {
            let state = bleStateReadHook?(key) ?? BLEManager.shared.state(for: key)
            if let state {
                applyBLEDerivedState(device.id, state, source: key, authoritativePower: reach != .wifi)
                return .briturn(state, via: .bluetooth)
            }
        }
        if let cloudDevice = briturnCloudDevices[device.id],
           let states = try? await briturnCloud.queryStates(devices: [cloudDevice]), let state = states[cloudDevice.canonicalID] {
            lastStatusAt[device.id] = Date()
            applyBriturnWireState(device.id, state, authoritative: true)
            return .briturn(state, via: .cloud)
        }
        return .unavailable(reach == .offline ? "offline (no WiFi, cloud or Bluetooth path)" : "no reply from the light")
    }

    /// Same gate BLEManager uses: the test host must never open real sockets.
    static let isUnderXCTest = NSClassFromString("XCTestCase") != nil

    /// The newest advert heard for the light, if any (BLE evidence timing).
    public func lastBLEAdvert(for device: Device) -> Date? {
        guard let key = bleKey(for: device) else { return nil }
        return bleLastAdvert(key)
    }
}

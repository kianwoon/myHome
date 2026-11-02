// Memoized derivations read by every dashboard card body. Cards observe the
// whole store, so each publish re-evaluates ~50 bodies: these values must be
// O(1) per read and rebuilt only when one of their inputs changes.

import Foundation

/// Cache storage (lives on DeviceStore; plain values, never published).
struct DerivedCaches {
    /// Uniform roster + BLE-only lights (`devices`); nil = rebuild.
    var devices: [Device]?
    /// `isBLELive(for:)` answers per device id.
    var bleLive: [String: Bool] = [:]
    /// Sorted capabilities per device id, with the spec they were built from.
    var capabilities: [String: (spec: [String: DPDeclaration]?, value: [Capability])] = [:]
    /// Number of capability lists built (test observability).
    var capabilityBuilds = 0
}

extension DeviceStore {
    /// Drops every memo derived from roster / BLE membership. Called from the
    /// didSet of each input (roster, cloud devices, BLE lights/seen/keys/groups,
    /// liveness test seams). `roster: true` also drops capability lists.
    func invalidateDerivedCaches(roster: Bool = false) {
        derivedCaches.devices = nil
        if !derivedCaches.bleLive.isEmpty { derivedCaches.bleLive.removeAll(keepingCapacity: true) }
        if roster { derivedCaches.capabilities.removeAll(keepingCapacity: true) }
    }

    /// `device.capabilities` (map + sort over the spec) built once per spec.
    /// Validated against the spec it was built from, since callers may pass
    /// a Device copy that is not the roster's (BLE-only lights, tests).
    func capabilities(for device: Device) -> [Capability] {
        if let hit = derivedCaches.capabilities[device.id], hit.spec == device.spec { return hit.value }
        let built = device.capabilities
        derivedCaches.capabilities[device.id] = (device.spec, built)
        derivedCaches.capabilityBuilds += 1
        return built
    }

    /// Last advert heard for a BLE key this run (nil = never).
    func bleLastAdvert(_ key: String) -> Date? {
        if let hook = bleLastAdvertHook { return hook(key) }
        return BLEManager.shared.lastAdvert(for: key)
    }
}

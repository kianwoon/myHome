// Compact device catalogue for the planner models. The on-device model's
// context is small (8,192 tokens shared by instructions, tool schemas, tool
// output and the answer), so devices are shown as short lines — handle, name,
// room, kind, current state, capabilities — under a character budget, with
// the devices that best match the request kept first. Handles ("d1") replace
// the long device ids; they map back to real ids when the plan is converted.
// The state column ("on 40%", "off", "offline", "?") lets the model reason
// about a situation ("stuffy" + fan off → turn it on); the controller still
// re-checks reachability and the user confirms every plan.
import Foundation

final class PlannerCatalogue: @unchecked Sendable {
    private let lock = NSLock()
    private var handleByID: [String: String] = [:]
    private var idByHandle: [String: String] = [:]
    private(set) var shown: [DeviceSummary] = []
    private(set) var omitted = 0
    let toolOutputBudget: Int

    /// Devices are ranked by overlap with `utterance` when they do not all fit
    /// within `budget` characters / `maxDevices` lines.
    init(devices: [DeviceSummary], utterance: String, budget: Int, maxDevices: Int, toolOutputBudget: Int) {
        self.toolOutputBudget = toolOutputBudget
        let usable = devices.filter(\.isControllable)
        for device in usable { _ = handle(for: device.id) }
        var chosen = Array(usable.enumerated())
        if Self.cost(of: usable.map { line(for: $0) }) > budget || usable.count > maxDevices {
            let wanted = Set(TextNormalizer.tokens(utterance))
            chosen.sort { lhs, rhs in
                let l = Self.score(lhs.element, wanted), r = Self.score(rhs.element, wanted)
                return l != r ? l > r : lhs.offset < rhs.offset
            }
        }
        var kept: [(offset: Int, element: DeviceSummary)] = []
        var used = 0
        for entry in chosen where kept.count < maxDevices {
            let cost = line(for: entry.element).count + 1
            if used + cost > budget, !kept.isEmpty { continue }
            used += cost
            kept.append(entry)
        }
        kept.sort { $0.offset < $1.offset }
        shown = kept.map(\.element)
        omitted = usable.count - shown.count
    }

    func handle(for id: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = handleByID[id] { return existing }
        let handle = "d\(handleByID.count + 1)"
        handleByID[id] = handle
        idByHandle[handle] = id
        return handle
    }

    /// The real device id behind a handle; ids the model copied verbatim pass through.
    func id(forHandle handle: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return idByHandle[handle.trimmingCharacters(in: .whitespaces).lowercased()] ?? handle
    }

    func line(for device: DeviceSummary) -> String {
        var parts = [handle(for: device.id), device.name]
        if !device.room.isEmpty { parts.append(device.room) }
        parts.append(device.kind.rawValue)
        parts.append(Self.state(of: device))
        parts.append(device.capabilities.map(\.rawValue).joined(separator: ","))
        return parts.joined(separator: "|")
    }

    /// Header naming the columns of `line(for:)` (room is omitted when empty).
    static let columns = "handle|name|room|kind|state|can"

    /// "on 40%", "off", "offline" or "?" (never read).
    static func state(of device: DeviceSummary) -> String {
        if device.reachability == .offline { return "offline" }
        guard let on = device.isOn else { return "?" }
        guard on else { return "off" }
        return device.levelPercent.map { "on \($0)%" } ?? "on"
    }

    /// The prompt section: one line per kept device plus a pointer to the tools.
    func render() -> String {
        var text = shown.map { line(for: $0) }.joined(separator: "\n")
        if omitted > 0 { text += "\n(+\(omitted) more devices not shown; call findDevices)" }
        return text
    }

    /// Tool output: same line format, cut to the tool budget.
    func render(_ devices: [DeviceSummary]) -> String {
        var out = ""
        var count = 0
        for device in devices {
            let next = line(for: device) + "\n"
            if out.count + next.count > toolOutputBudget, count > 0 { break }
            out += next
            count += 1
        }
        if count < devices.count { out += "(+\(devices.count - count) more; narrow the phrase)" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cost(of lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.count + 1 }
    }

    private static func score(_ device: DeviceSummary, _ wanted: Set<String>) -> Int {
        let own = Set(TextNormalizer.tokens([device.name, device.room, device.group ?? "", device.kind.rawValue].joined(separator: " ")))
        return own.intersection(wanted).count
    }
}

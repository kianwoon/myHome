// Stable short handles for the agent ("light-8e6d", "fan-to2l"): the kind
// word plus the tail of the device id, so the model copies a name it can
// read, two namesakes never collide, and a handle means the same device
// in every turn and every session. Also derives a room for Briturn lights,
// whose roster entry only carries a group ("study room Front" → Study room),
// and renders the live snapshot the system prompt carries.
import Foundation

public struct DeviceHandles: Equatable, Sendable {
    public static let idTailLength = 4
    public static let noRoomMarker = "-"

    public private(set) var devices: [DeviceSummary]
    private var deviceByHandle: [String: DeviceSummary] = [:]
    private var handleByID: [String: String] = [:]
    private var roomByID: [String: String] = [:]
    /// Rooms named on roster entries, in first-seen order.
    public private(set) var rooms: [String] = []

    public init(devices: [DeviceSummary]) {
        self.devices = devices
        var seenRooms = Set<String>()
        for device in devices where !device.room.isEmpty && seenRooms.insert(device.room).inserted { rooms.append(device.room) }
        for device in devices {
            let handle = Self.uniqueHandle(for: device, taken: deviceByHandle)
            deviceByHandle[handle] = device
            handleByID[device.id] = handle
            roomByID[device.id] = Self.derivedRoom(for: device, rooms: rooms)
        }
    }

    public func handle(for id: String) -> String? { handleByID[id] }

    /// Case-insensitive, whitespace-tolerant lookup; the raw id passes too.
    public func device(for handle: String) -> DeviceSummary? {
        let key = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let device = deviceByHandle[key] { return device }
        return devices.first { $0.id.lowercased() == key }
    }

    /// The device's room, or the room its Briturn group belongs to, or "".
    public func room(for device: DeviceSummary) -> String { roomByID[device.id] ?? device.room }

    static func uniqueHandle(for device: DeviceSummary, taken: [String: DeviceSummary]) -> String {
        let word = device.kind == .unknown ? "device" : device.kind.rawValue
        let tail = device.id.lowercased().filter { $0.isLetter || $0.isNumber }
        var length = idTailLength
        while length <= max(tail.count, idTailLength) {
            let candidate = "\(word)-\(tail.suffix(length))"
            if taken[candidate] == nil { return candidate }
            length += 1
        }
        var counter = 2
        while taken["\(word)-\(tail)-\(counter)"] != nil { counter += 1 }
        return "\(word)-\(tail)-\(counter)"
    }

    /// A group belongs to the roster room whose leading word it carries
    /// ("master middle" → "Master room"); otherwise the group itself is the area.
    static func derivedRoom(for device: DeviceSummary, rooms: [String]) -> String {
        if !device.room.isEmpty { return device.room }
        guard let group = device.group, !group.isEmpty else { return "" }
        let groupTokens = Set(TextNormalizer.tokens(group))
        for room in rooms {
            guard let lead = TextNormalizer.tokens(room, stopWords: ResolverVocabulary.standard.stopWords).first else { continue }
            if groupTokens.contains(lead) { return room }
        }
        return group
    }
}

/// The compact live snapshot of every device for the system prompt and the
/// list/get tools: one line per device, under a character budget.
public enum HousekeeperSnapshot {
    public static let columns = "handle | name | room | group | kind | state | reach | can"
    static let notControllable = "NOT CONTROLLABLE (no control path)"
    static let unknownBluetooth = "unknown (bluetooth, may be on)"

    /// Extra per-device detail the renderer cannot derive from a summary
    /// (a fan's gear and gear count); nil when there is none.
    public typealias Detail = (DeviceSummary) -> String?

    public static func line(for device: DeviceSummary, handles: DeviceHandles, detail: Detail? = nil) -> String {
        let room = handles.room(for: device)
        let state = stateText(device, detail: detail?(device))
        let reach = device.isControllable ? device.reachability.rawValue : notControllable
        let can = device.isControllable ? capabilities(of: device) : "-"
        return [handles.handle(for: device.id) ?? device.id, device.name, room.isEmpty ? DeviceHandles.noRoomMarker : room,
                device.group ?? DeviceHandles.noRoomMarker, kindText(device.kind), state, reach, can].joined(separator: " | ")
    }

    public static func render(_ devices: [DeviceSummary], handles: DeviceHandles, budget: Int, maxDevices: Int, detail: Detail? = nil) -> String {
        var lines: [String] = []
        var used = 0
        var omitted = 0
        for device in devices {
            let next = line(for: device, handles: handles, detail: detail)
            if lines.count >= maxDevices || used + next.count + 1 > budget { omitted += 1; continue }
            used += next.count + 1
            lines.append(next)
        }
        var text = lines.joined(separator: "\n")
        if omitted > 0 { text += "\n(+\(omitted) more not shown; use list_devices with a room or kind)" }
        return text
    }

    static func stateText(_ device: DeviceSummary, detail: String?) -> String {
        if device.reachability == .offline { return "offline" }
        guard let on = device.isOn else {
            // A Bluetooth-only light has no read-back: its state is unknown,
            // not off, and it may well be lit.
            return device.reachability == .bluetooth ? unknownBluetooth : "? (no reading yet)"
        }
        guard on else { return "off" }
        if let detail { return "on, \(detail)" }
        if let level = device.levelPercent {
            return device.kind == .fan ? "on, speed \(level)%" : "on \(level)%"
        }
        return "on"
    }

    // allow-hardcode: wording of kinds for the model (descriptive labels, not matching logic).
    static func kindText(_ kind: DeviceKind) -> String {
        switch kind {
        case .plug: return "plug (smart socket, power only)"
        case .kettle: return "appliance socket"
        case .unknown: return "device"
        default: return kind.rawValue
        }
    }

    /// Colour is left out: the agent has no colour action (Tuya colour needs an encoder).
    static func capabilities(of device: DeviceSummary) -> String {
        device.capabilities.filter { $0 != .color }.map { capability -> String in
            switch capability {
            case .level: return device.kind == .fan ? "level(speed %)" : (device.kind == .curtain ? "level(position %)" : "level(brightness %)")
            case .fanSpeed: return "fan_speed(gear)"
            case .colorTemperature: return "color_temperature(0 warm-100 cool)"
            case .openClose: return "open/close/stop"
            case .media: return "play(station name or 'music')/pause/resume/stop"
            case .volume: return "volume(0-100)"
            case .mute: return "mute/unmute"
            case .input: return "input(wifi, bluetooth, tv, optical, aux, usb)"
            case .power: return "power_on/power_off"
            case .mode: return "mode"
            case .color: return "color"
            }
        }.joined(separator: ", ")
    }
}

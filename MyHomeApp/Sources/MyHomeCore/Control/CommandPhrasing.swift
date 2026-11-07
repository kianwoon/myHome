// Human-readable (spoken) summaries of commands and results. UI copy only —
// no decisions are made here. Every string is built from the structured
// result, so the same phrasing serves the command bar, Siri dialog and TTS.
import Foundation

public enum CommandPhrasing {
    // MARK: Commands

    /// Imperative form: "turn on", "set … to 50%".
    public static func action(_ command: DeviceCommand, target: String) -> String {
        switch command {
        case .power(let on): return "\(on ? "Turn on" : "Turn off") \(target)"
        case .level(let percent): return "Set \(target) to \(percent)%"
        case .color(let rgb): return "Set \(target) to colour \(rgb.red), \(rgb.green), \(rgb.blue)"
        case .colorTemperature(let percent): return "Set \(target) to \(percent)% cool white"
        case .mode(let mode): return "Set \(target) to \(mode) mode"
        case .fanSpeed(let gear): return "Set \(target) to speed \(gear)"
        case .cover(let action): return "\(action.rawValue.capitalized) \(target)"
        case .volume(let percent): return "Set \(target) volume to \(percent)%"
        case .mute(let muted): return "\(muted ? "Mute" : "Unmute") \(target)"
        case .input(let name): return "Switch \(target) to \(name)"
        }
    }

    /// Past tense for a success: "Turned on", "Set … to 50%".
    public static func done(_ command: DeviceCommand, target: String) -> String {
        switch command {
        case .power(let on): return "\(on ? "Turned on" : "Turned off") \(target)"
        case .cover(let action):
            switch action {
            case .open: return "Opened \(target)"
            case .close: return "Closed \(target)"
            case .stop: return "Stopped \(target)"
            }
        case .mute(let muted): return "\(muted ? "Muted" : "Unmuted") \(target)"
        case .input(let name): return "Switched \(target) to \(name)"
        default: return action(command, target: target)
        }
    }

    public static func targetPhrase(_ devices: [DeviceSummary], scope: ResolutionScope?) -> String {
        if devices.count == 1 { return devices[0].name }
        // "2 lights in Study" when every target is the same kind, else "2 devices in Study".
        let sharedKind = Set(devices.map(\.kind)).count == 1 ? devices.first?.kind : nil
        let noun = sharedKind.map { plural($0.label.lowercased()) } ?? "devices"
        switch scope {
        case .room(let room)?: return "\(devices.count) \(noun) in \(room)"
        case .group(let group)?: return "\(devices.count) \(group) lights"
        case .kind(let kind)?: return "\(devices.count) \(plural(kind.label.lowercased()))"
        default: return "\(devices.count) \(noun)"
        }
    }

    // MARK: Results

    public static func summary(for result: CommandResult) -> String {
        switch result.disposition {
        case .nothingToDo(let reason):
            return reason
        case .ambiguous(let candidates):
            let question = "Which one: \(list(candidates.map(\.name), conjunction: "or"))?"
            // Namesakes set aside for having no control path are still named.
            return result.outcomes.isEmpty ? question : "\(question) (\(failures(result.outcomes)).)"
        case .needsConfirmation:
            return "\(action(result.command, target: targetPhrase(result.outcomes.map(\.device), scope: result.scope)))?"
        case .executed:
            return executedSummary(result)
        }
    }

    /// Confirmed devices are stated as done; every unverified or failed device
    /// is named with its reason — a sent-but-unconfirmed light is never folded
    /// into "Turned on 4 lights".
    private static func executedSummary(_ result: CommandResult) -> String {
        let good = result.outcomes.filter { $0.status.isSuccess }
        let pending = result.outcomes.filter { $0.status.isUnverified }
        let bad = result.outcomes.filter { !$0.status.isSuccess && !$0.status.isUnverified }
        var parts: [String] = []
        if !good.isEmpty {
            let all = result.outcomes.count == good.count
            let target = all ? targetPhrase(good.map(\.device), scope: result.scope)
                : "\(good.count) of \(targetPhrase(result.outcomes.map(\.device), scope: result.scope))"
            parts.append(done(result.command, target: target))
        } else if !pending.isEmpty {
            parts.append("Sent \(lowercasedVerb(action(result.command, target: targetPhrase(pending.map(\.device), scope: result.scope))))")
        }
        if !pending.isEmpty {
            let names = list(pending.map { "\($0.device.name) \($0.status.reason)" }, conjunction: "and")
            parts.append(good.isEmpty ? "\(names)" : names)
        }
        if !bad.isEmpty {
            if good.isEmpty, pending.isEmpty {
                if bad.count == 1 { return "Couldn't \(lowercasedVerb(action(result.command, target: bad[0].device.name))): \(bad[0].status.reason)." }
                return "Couldn't \(lowercasedVerb(action(result.command, target: targetPhrase(bad.map(\.device), scope: result.scope)))): \(failures(bad))."
            }
            parts.append(failures(bad))
        }
        return parts.joined(separator: "; ") + "."
    }

    private static func failures(_ outcomes: [DeviceOutcome]) -> String {
        list(outcomes.map { "\($0.device.name) \($0.status.reason)" }, conjunction: "and")
    }

    public static func list(_ items: [String], conjunction: String) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) \(conjunction) \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", \(conjunction) \(items[items.count - 1])"
        }
    }

    // MARK: Status

    public static func describe(_ device: DeviceSummary) -> String {
        if let speaker = device.speaker { return describeSpeaker(device, speaker) }
        var parts: [String] = []
        if let on = device.isOn { parts.append(on ? "on" : "off") }
        if let level = device.levelPercent, device.isOn != false {
            parts.append(device.kind == .fan ? "speed \(level)%" : "at \(level)%")
        }
        if device.reachability == .offline { parts.append("offline") }
        if parts.isEmpty { return "\(device.name): state unknown" }
        return "\(device.name) is \(parts.joined(separator: ", "))"
    }

    /// Speaker status from confirmed readings; stale values are labelled, never presented as current.
    static func describeSpeaker(_ device: DeviceSummary, _ speaker: DeviceSummary.SpeakerSummary) -> String {
        if device.reachability == .offline { return "\(device.name) is offline" + (speaker.volume.map { " (last known volume \($0)%)" } ?? "") }
        var parts: [String] = []
        if let on = device.isOn { parts.append(on ? "on" : "in standby") }
        if let volume = speaker.volume { parts.append("volume \(volume)%") }
        if let muted = speaker.muted { parts.append(muted ? "muted" : "not muted") }
        if let input = speaker.inputLabel { parts.append("input \(input)") }
        if parts.isEmpty { return "\(device.name): state unknown" }
        let stale = speaker.isStale ? " (last known" + (speaker.secondsSinceUpdate.map { ", \($0)s ago" } ?? "") + ")" : ""
        return "\(device.name) is \(parts.joined(separator: ", "))\(stale)"
    }

    static func plural(_ noun: String) -> String {
        noun.hasSuffix("s") ? noun : noun + "s"
    }

    /// "Turn on Study Fan" → "turn on Study Fan" (device names keep their case).
    static func lowercasedVerb(_ phrase: String) -> String {
        guard let first = phrase.first else { return phrase }
        return first.lowercased() + phrase.dropFirst()
    }
}

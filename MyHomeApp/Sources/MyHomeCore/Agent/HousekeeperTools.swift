// The housekeeper's tools: what the model may do, and the code that does it.
// Reads are deterministic (counts and states come from the registry, never
// from the model); every write goes through DeviceController's policy and
// execution (check + perform), so an unreachable or unsupported device is
// refused by code and the refusal travels back in the tool result. Nothing
// here resolves names: the model names devices by handle only.
import Foundation

// allow-hardcode: tool names, descriptions and schemas are the model-facing contract (reviewed guidance).
public enum HousekeeperAction: String, CaseIterable, Sendable {
    case powerOn = "power_on", powerOff = "power_off", level, fanSpeed = "fan_speed", colorTemperature = "color_temperature"
    case open, close, stop, mode
    case volume, mute, unmute, input

    public static let names = allCases.map(\.rawValue).joined(separator: ", ")

    public struct ArgumentError: Error, Equatable { public let message: String }

    /// The semantic command for this action and (where needed) its value.
    public func command(value: JSONValue?) -> Result<DeviceCommand, ArgumentError> {
        switch self {
        case .powerOn: return .success(.power(true))
        case .powerOff: return .success(.power(false))
        case .open: return .success(.cover(.open))
        case .close: return .success(.cover(.close))
        case .stop: return .success(.cover(.stop))
        case .mute: return .success(.mute(true))
        case .unmute: return .success(.mute(false))
        case .volume:
            guard let number = HousekeeperTools.integer(value), Percent.range.contains(number) else {
                return .failure(ArgumentError(message: "volume needs an integer value \(Percent.range.lowerBound)-\(Percent.range.upperBound)"))
            }
            return .success(.volume(number))
        case .input:
            guard let text = value?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return .failure(ArgumentError(message: "input needs a source name (wifi, bluetooth, tv, optical, aux, usb)")) }
            return .success(.input(text))
        case .mode:
            guard let text = value?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return .failure(ArgumentError(message: "mode needs a string value")) }
            return .success(.mode(text))
        case .level, .colorTemperature:
            guard let number = HousekeeperTools.integer(value), Percent.range.contains(number) else {
                return .failure(ArgumentError(message: "\(rawValue) needs an integer value \(Percent.range.lowerBound)-\(Percent.range.upperBound)"))
            }
            return .success(self == .level ? .level(number) : .colorTemperature(number))
        case .fanSpeed:
            guard let gear = HousekeeperTools.integer(value), gear >= 1 else { return .failure(ArgumentError(message: "fan_speed needs a gear number from 1")) }
            return .success(.fanSpeed(gear))
        }
    }
}

@MainActor
public final class HousekeeperTools {
    public enum Outcome: Equatable {
        case result(String)
        case error(String)
        /// A set the policy wants confirmed: the requests to run on "yes".
        case needsConfirmation(requests: [CommandRequest], description: String)
        case askUser(String)
    }

    public enum Name: String, CaseIterable {
        case listDevices = "list_devices", getState = "get_state", count, set, undoLast = "undo_last", now
        case remember, recallNotes = "recall_notes", forget, askUser = "ask_user"
    }

    public let controller: DeviceController
    public let notes: HouseholdNotes
    public var policy: HousekeeperPolicy
    public var outputBudget: Int
    public var clock: () -> Date
    public var calendar = Calendar.current
    public private(set) var handles: DeviceHandles
    /// Results of every set this turn (for the reply's veto report).
    public private(set) var executed: [CommandResult] = []
    /// One line per action this turn, for the conversation memory.
    public private(set) var actionNotes: [String] = []
    /// What the last set changed (device state before it), for undo_last.
    private var undoEntry: [(before: DeviceSummary, command: DeviceCommand)] = []
    /// The write waiting for the household's "yes" (see `applyConfirmed`).
    private var pendingApply: (command: DeviceCommand, summaries: [DeviceSummary])?

    public init(controller: DeviceController, notes: HouseholdNotes, policy: HousekeeperPolicy = HousekeeperPolicy(),
                outputBudget: Int = AppSettings.defaultHousekeeperToolOutputBudget, clock: @escaping () -> Date = { Date() }) {
        self.controller = controller
        self.notes = notes
        self.policy = policy
        self.outputBudget = outputBudget
        self.clock = clock
        handles = DeviceHandles(devices: controller.summaries())
    }

    /// Re-reads the registry (state changes between and within turns).
    public func refresh() {
        handles = DeviceHandles(devices: controller.summaries())
    }

    public func beginTurn() {
        refresh()
        executed = []
        actionNotes = []
        pendingApply = nil
    }

    public var hasPendingConfirmation: Bool { pendingApply != nil }
    public var pendingDeviceCount: Int { pendingApply?.summaries.count ?? 0 }
    public func clearPendingConfirmation() { pendingApply = nil }

    /// Runs the write the household just confirmed through the SAME path as an
    /// unconfirmed set: fans powered on first, undo recorded, outcomes kept in
    /// `executed`. Returns the results of this confirmation only.
    public func applyConfirmed() async -> [CommandResult] {
        guard let plan = pendingApply else { return [] }
        pendingApply = nil
        let start = executed.count
        _ = await apply(plan.command, to: plan.summaries, unknown: [], confirmed: true)
        return Array(executed[start...])
    }

    public var hasSideEffects: Bool { !executed.isEmpty }

    // MARK: - Definitions

    nonisolated static let stateValues: JSONValue = .array([.string("on"), .string("off"), .string("any")])
    nonisolated static let kindValues: JSONValue = .array([DeviceKind.light, .fan, .curtain, .plug, .climate, .purifier, .kettle, .unknown].map { .string($0.rawValue) })

    nonisolated static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
        return .object(object)
    }

    nonisolated static func property(_ type: String, _ description: String, enumValues: JSONValue? = nil, items: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "description": .string(description)]
        if let enumValues { object["enum"] = enumValues }
        if let items { object["items"] = items }
        return .object(object)
    }

    public nonisolated static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(name: Name.listDevices.rawValue,
                            description: "List devices with their live state, optionally filtered by room (words matched against room and group), kind, or on/off state. The system prompt already lists every device; use this to re-check after changes.",
                            parameters: schema(["room": property("string", "Room or group words, e.g. study"),
                                                "kind": property("string", "Device kind", enumValues: kindValues),
                                                "state": property("string", "Only devices in this state", enumValues: stateValues)])),
        AgentToolDefinition(name: Name.getState.rawValue,
                            description: "Current state of specific devices by handle.",
                            parameters: schema(["handles": property("array", "Device handles", items: .object(["type": .string("string")]))], required: ["handles"])),
        AgentToolDefinition(name: Name.count.rawValue,
                            description: "Count devices deterministically (how many lights are on, how many fans in the study). Returns counts and names; offline and unread devices are listed separately.",
                            parameters: schema(["kind": property("string", "Device kind", enumValues: kindValues),
                                                "room": property("string", "Room or group words"),
                                                "state": property("string", "on, off or any (default any)", enumValues: stateValues)])),
        AgentToolDefinition(name: Name.set.rawValue,
                            description: "Change devices. Pass ONLY the handles that should change. Actions: \(HousekeeperAction.names). value: percent 0-100 for level/color_temperature, gear number for fan_speed, mode name for mode, percent 0-100 for volume (speakers), source name for input (speakers: wifi, bluetooth, tv, optical, aux, usb). A fan that is off is powered on automatically when its speed or level is set. Every device is checked by the house: unreachable or unsupported ones are refused in the result and must be mentioned in your reply.",
                            parameters: schema(["handles": property("array", "Device handles to change", items: .object(["type": .string("string")])),
                                                "action": property("string", "What to do", enumValues: .array(HousekeeperAction.allCases.map { .string($0.rawValue) })),
                                                "value": .object(["description": .string("Number (level, color_temperature, fan_speed, volume) or mode/input name")])],
                                               required: ["handles", "action"])),
        AgentToolDefinition(name: Name.undoLast.rawValue, description: "Put the devices changed by the last set back to their previous state.",
                            parameters: schema([:])),
        AgentToolDefinition(name: Name.now.rawValue, description: "Local date, time, weekday and part of day.", parameters: schema([:])),
        AgentToolDefinition(name: Name.remember.rawValue,
                            description: "Save a household note for future conversations. Only when the household says \"remember …\" or corrects you.",
                            parameters: schema(["note": property("string", "The note, one sentence")], required: ["note"])),
        AgentToolDefinition(name: Name.recallNotes.rawValue, description: "List the saved household notes with their ids.", parameters: schema([:])),
        AgentToolDefinition(name: Name.forget.rawValue, description: "Delete a household note by id.",
                            parameters: schema(["id": property("string", "Note id (the bracketed id from the notes list)")], required: ["id"])),
        AgentToolDefinition(name: Name.askUser.rawValue,
                            description: "Ask the household ONE short question and stop; use it only when the request cannot be settled from the device list and state. This is the only way to ask.",
                            parameters: schema(["question": property("string", "The question")], required: ["question"])),
    ]

    // MARK: - Execution

    public func execute(_ call: AgentToolCall) async -> Outcome {
        guard let name = Name(rawValue: call.name.lowercased()) else {
            return .error("unknown tool \(call.name); available: \(Name.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        refresh()
        switch name {
        case .listDevices: return .result(listDevices(call.arguments))
        case .getState: return getState(call.arguments)
        case .count: return .result(count(call.arguments))
        case .set: return await set(call.arguments)
        case .undoLast: return await undoLast()
        case .now: return .result(now())
        case .remember:
            guard let text = call.arguments["note"]?.stringValue, let note = notes.add(text) else { return .error("note needs non-empty text") }
            actionNotes.append("remembered: \(note.text)")
            return .result("saved note [\(note.id.prefix(8))]: \(note.text)")
        case .recallNotes:
            return .result(notes.notes.isEmpty ? "(no household notes)" : notes.rendered())
        case .forget:
            guard let id = call.arguments["id"]?.stringValue, let note = notes.note(matching: id) else { return .error("no note with that id; call recall_notes for the ids") }
            notes.remove(id: note.id)
            actionNotes.append("forgot note: \(note.text)")
            return .result("deleted note: \(note.text)")
        case .askUser:
            guard let question = call.arguments["question"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
                return .error("ask_user needs a question")
            }
            return .askUser(question)
        }
    }

    // MARK: Reads

    private func listDevices(_ arguments: [String: JSONValue]) -> String {
        let pool = filtered(arguments)
        guard !pool.isEmpty else { return "no devices match that filter" }
        return HousekeeperSnapshot.columns + "\n" + HousekeeperSnapshot.render(pool, handles: handles, budget: outputBudget, maxDevices: Int.max, detail: detail)
    }

    private func getState(_ arguments: [String: JSONValue]) -> Outcome {
        let (devices, unknown) = resolveHandles(arguments["handles"])
        guard !devices.isEmpty else { return .error(unknownHandlesMessage(unknown)) }
        var text = HousekeeperSnapshot.columns + "\n" + HousekeeperSnapshot.render(devices, handles: handles, budget: outputBudget, maxDevices: Int.max, detail: detail)
        if !unknown.isEmpty { text += "\nunknown handles ignored: \(unknown.joined(separator: ", "))" }
        return .result(text)
    }

    private func count(_ arguments: [String: JSONValue]) -> String {
        var scoped = arguments
        if scoped["state"] == nil { scoped["state"] = .string("any") }
        let pool = filtered(scoped, ignoringState: true)
        let wanted = arguments["state"]?.stringValue?.lowercased() ?? "any"
        let offline = pool.filter { $0.reachability == .offline }
        let unknown = pool.filter { $0.reachability != .offline && $0.isOn == nil }
        let readable = pool.filter { $0.reachability != .offline && $0.isOn != nil }
        let on = readable.filter { $0.isOn == true }
        let off = readable.filter { $0.isOn == false }
        let hits = wanted == "on" ? on : (wanted == "off" ? off : pool)
        let names: (any Sequence<DeviceSummary>) -> JSONValue = { items in
            .array(items.map { .string("\(self.handles.handle(for: $0.id) ?? $0.id) \($0.name)") })
        }
        let object: [String: JSONValue] = [
            "count": .number(Double(hits.count)), "state": .string(wanted), "matched_total": .number(Double(pool.count)),
            "on": .number(Double(on.count)), "off": .number(Double(off.count)),
            "offline": .number(Double(offline.count)), "no_reading": .number(Double(unknown.count)),
            "names": names(hits), "offline_names": names(offline), "no_reading_names": names(unknown),
        ]
        return JSONValue.object(object).jsonText
    }

    private func now() -> String {
        let date = clock()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        let dayText = formatter.string(from: date)
        formatter.dateFormat = "HH:mm"
        let timeText = formatter.string(from: date)
        let hour = calendar.component(.hour, from: date)
        let object: [String: JSONValue] = ["date": .string(dayText), "time": .string(timeText),
                                           "part_of_day": .string(Self.partOfDay(hour: hour)), "timezone": .string(calendar.timeZone.identifier)]
        return JSONValue.object(object).jsonText
    }

    // allow-hardcode: the names of the parts of a day and the hours they start at (wording, not a threshold the code tunes).
    static let partsOfDay: [(startHour: Int, name: String)] = [(5, "morning"), (12, "afternoon"), (17, "evening"), (21, "night")]

    static func partOfDay(hour: Int) -> String {
        var name = partsOfDay.last?.name ?? ""
        for part in partsOfDay where hour >= part.startHour { name = part.name }
        return name
    }

    // MARK: Writes

    private func set(_ arguments: [String: JSONValue]) async -> Outcome {
        let (summaries, unknown) = resolveHandles(arguments["handles"])
        guard !summaries.isEmpty else { return .error(unknownHandlesMessage(unknown)) }
        guard let actionName = arguments["action"]?.stringValue?.lowercased(), let action = HousekeeperAction(rawValue: actionName) else {
            return .error("action must be one of: \(HousekeeperAction.names)")
        }
        let command: DeviceCommand
        switch action.command(value: arguments["value"]) {
        case .success(let built): command = built
        case .failure(let reason): return .error(reason.message)
        }
        return await apply(command, to: summaries, unknown: unknown, confirmed: false)
    }

    private func apply(_ command: DeviceCommand, to summaries: [DeviceSummary], unknown: [String], confirmed: Bool) async -> Outcome {
        let devices = summaries.compactMap { controller.device(id: $0.id) }
        let requests = Self.requests(for: devices, command: command, store: controller.store)
        if !confirmed, let reason = policy.confirmationReason(for: summaries, command: command, handles: handles) {
            let target = CommandPhrasing.targetPhrase(summaries, scope: nil)
            pendingApply = (command, summaries)
            return .needsConfirmation(requests: requests, description: "\(CommandPhrasing.action(command, target: target)) (\(reason))")
        }
        // The state as it is NOW (not the caller's snapshot) is what undo restores.
        undoEntry = devices.map { (before: controller.summary(for: $0), command: command) }
        var outcomes: [DeviceOutcome] = []
        // A speed or level on a fan that is off means "run it": power it on first
        // (a Tuya fan stores a gear while off and stays still).
        let sleepingFans = Self.needsPowerFirst(command) ? devices.filter { $0.kind == .fan && controller.store.power(for: $0) == false } : []
        for fan in sleepingFans {
            let result = await controller.perform(CommandRequest(resolution: .single(fan), command: .power(true), origin: .model, confirmed: true))
            executed.append(result)
            outcomes.append(contentsOf: result.outcomes.map { DeviceOutcome(device: $0.device, status: $0.status) })
        }
        for request in requests {
            let result = await controller.perform(request)
            executed.append(result)
            outcomes.append(contentsOf: result.outcomes)
        }
        let confirmed = outcomes.filter { $0.status.isSuccess }
        let unverified = outcomes.filter { $0.status.isUnverified }
        let failed = outcomes.filter { !$0.status.wasSent }
        actionNotes.append("\(CommandPhrasing.action(command, target: "")) → " + outcomes.map { outcome in
            "\(handles.handle(for: outcome.device.id) ?? outcome.device.name) \(outcome.status.label)"
        }.joined(separator: ", "))
        let poweredOn = Set(sleepingFans.map(\.id))
        var lines = outcomes.map { outcome -> String in
            let handle = handles.handle(for: outcome.device.id) ?? outcome.device.id
            let note = poweredOn.contains(outcome.device.id) ? " (was off: turned on first)" : ""
            let now = controller.device(id: outcome.device.id).map { CommandPhrasing.describe(controller.summary(for: $0)) } ?? CommandPhrasing.describe(outcome.device)
            switch outcome.status {
            case .confirmed: return "\(handle) \(outcome.device.name): CONFIRMED by read-back\(note) — \(now)"
            case .unverified(let text): return "\(handle) \(outcome.device.name): SENT, NOT CONFIRMED — \(text)"
            case .uncertain(let text): return "\(handle) \(outcome.device.name): UNCERTAIN — \(text)"
            case .rejected(let text): return "\(handle) \(outcome.device.name): FAILED — \(text)"
            case .denied(let text): return "\(handle) \(outcome.device.name): REFUSED — \(text)"
            case .unsupported(let text): return "\(handle) \(outcome.device.name): UNSUPPORTED — \(text)"
            }
        }
        var summary = "\(confirmed.count) of \(outcomes.count) confirmed"
        if !unverified.isEmpty { summary += ", \(unverified.count) sent but not confirmed" }
        if !failed.isEmpty { summary += ", \(failed.count) failed or refused" }
        if confirmed.count < outcomes.count { summary += ". Tell the household exactly which were confirmed, which are unconfirmed and which failed; never call an unconfirmed one done." }
        lines.append(summary)
        if !sleepingFans.isEmpty { lines.append("note: \(sleepingFans.count == 1 ? "a fan that was off was" : "fans that were off were") powered on before the speed was set") }
        if !unknown.isEmpty { lines.append("unknown handles ignored: \(unknown.joined(separator: ", "))") }
        return .result(lines.joined(separator: "\n"))
    }

    private func undoLast() async -> Outcome {
        guard !undoEntry.isEmpty else { return .error("nothing to undo") }
        let entry = undoEntry
        undoEntry = []
        var texts: [String] = []
        for item in entry {
            guard let device = controller.device(id: item.before.id) else { continue }
            let commands: [DeviceCommand]
            switch item.command {
            case .power: commands = item.before.isOn.map { [.power($0)] } ?? []
            case .level, .fanSpeed:
                var list: [DeviceCommand] = []
                if let level = item.before.levelPercent { list.append(.level(level)) }
                if item.before.isOn == false { list.append(.power(false)) }
                commands = list
            case .mute:
                commands = item.before.speaker?.muted.map { [.mute($0)] } ?? []
            case .volume:
                commands = item.before.speaker?.volume.map { [.volume($0)] } ?? []
            default: commands = []
            }
            guard !commands.isEmpty else {
                texts.append("\(handles.handle(for: device.id) ?? device.name): previous state unknown, not undone")
                continue
            }
            for command in commands {
                let outcome = await apply(command, to: [item.before], unknown: [], confirmed: true)
                if case .result(let text) = outcome { texts.append(text) }
            }
        }
        return .result(texts.joined(separator: "\n"))
    }

    /// Speeds and levels on a fan only mean something while it runs.
    nonisolated static func needsPowerFirst(_ command: DeviceCommand) -> Bool {
        switch command {
        case .fanSpeed, .level: return true
        default: return false
        }
    }

    /// One request for the whole target set: the controller writes and
    /// verifies every device on its own transport (never a group write that
    /// can drop a member).
    static func requests(for devices: [Device], command: DeviceCommand, store: DeviceStore) -> [CommandRequest] {
        if devices.count == 1 {
            return [CommandRequest(resolution: .single(devices[0]), command: command, origin: .model, confirmed: true)]
        }
        guard !devices.isEmpty else { return [] }
        return [CommandRequest(resolution: .set(devices, scope: .all), command: command, origin: .model, confirmed: true)]
    }

    // MARK: - Argument helpers

    /// Handles from an array, a single string, or a comma-separated string.
    func resolveHandles(_ value: JSONValue?) -> (devices: [DeviceSummary], unknown: [String]) {
        var names: [String] = []
        switch value {
        case .array(let items)?: names = items.compactMap { $0.stringValue ?? $0.doubleValue.map { String(Int($0)) } }
        case .string(let text)?: names = text.split(separator: ",").map { String($0) }
        default: break
        }
        var devices: [DeviceSummary] = []
        var unknown: [String] = []
        var seen = Set<String>()
        for name in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty {
            if let device = handles.device(for: name) {
                if seen.insert(device.id).inserted { devices.append(device) }
            } else {
                unknown.append(name)
            }
        }
        return (devices, unknown)
    }

    func unknownHandlesMessage(_ unknown: [String]) -> String {
        unknown.isEmpty ? "handles must name at least one device from the list"
            : "unknown handles: \(unknown.joined(separator: ", ")). Use the handles from the device list (first column)."
    }

    nonisolated static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .number(let number)?: return Int(number.rounded())
        case .string(let text)?:
            let digits = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            return Int(digits) ?? Double(digits).map { Int($0.rounded()) }
        default: return nil
        }
    }

    /// Room / kind / state filter over the registry, matched like the resolver does.
    private func filtered(_ arguments: [String: JSONValue], ignoringState: Bool = false) -> [DeviceSummary] {
        let kind = arguments["kind"]?.stringValue.flatMap { word -> DeviceKind? in
            DeviceKind(rawValue: word.lowercased()) ?? ResolverVocabulary.standard.kind(for: TextNormalizer.fold(word))
        }
        let roomTokens = TextNormalizer.tokens(arguments["room"]?.stringValue ?? "", stopWords: ResolverVocabulary.standard.stopWords)
        let state = ignoringState ? nil : arguments["state"]?.stringValue?.lowercased()
        return handles.devices.filter { device in
            if let kind, device.kind != kind { return false }
            if !roomTokens.isEmpty {
                let own = Set(TextNormalizer.tokens([device.room, handles.room(for: device), device.group ?? "", device.name].joined(separator: " ")))
                if !roomTokens.allSatisfy(own.contains) { return false }
            }
            switch state {
            case "on": return device.isOn == true
            case "off": return device.isOn == false
            default: return true
            }
        }
    }

    /// A fan's gear out of its gear count ("speed 3 of 6").
    var detail: HousekeeperSnapshot.Detail {
        { [weak self] summary in
            guard let self, summary.kind == .fan, summary.isOn == true, let device = self.controller.device(id: summary.id) else { return nil }
            let state = self.controller.store.state(for: device)
            guard state.fanSpeedKey != nil else { return nil }
            return "speed \(state.fanSpeed) of \(state.fanSpeedMax)"
        }
    }

    /// What the reply must not leave out: refused/failed devices as "Not done",
    /// sent-but-unconfirmed ones as "Not yet confirmed". ALWAYS emitted for
    /// every non-confirmed outcome: a reply that merely names the device
    /// ("the study room lights are dimmed") is not a status report, so the
    /// model's text is never used to suppress it.
    public func vetoReport(missingFrom text: String) -> String? {
        let outcomes = executed.flatMap(\.outcomes)
        let failed = outcomes.filter { !$0.status.wasSent }
        let pending = outcomes.filter { $0.status.isUnverified }
        var parts: [String] = []
        if !failed.isEmpty {
            parts.append("Not done: " + CommandPhrasing.list(failed.map { "\($0.device.name) \($0.status.reason)" }, conjunction: "and") + ".")
        }
        if !pending.isEmpty {
            parts.append("Not yet confirmed by the device: " + CommandPhrasing.list(pending.map { "\($0.device.name) (\($0.status.reason))" }, conjunction: "and") + ".")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Re-reads stale devices (bounded) so the snapshot the model sees is current.
    public func freshen(maxAge: TimeInterval, within seconds: TimeInterval) async {
        let store = controller.store
        let devices = store.devices
        let started = Date()
        _ = await Deadline.run(seconds: seconds) { @MainActor in await store.refreshStale(devices, maxAge: maxAge) }
        let unknown = controller.summaries().filter { $0.isControllable && $0.isOn == nil }.count
        AppLog.assistant.notice("housekeeper freshen: took=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms controllableWithoutReading=\(unknown, privacy: .public)")
        refresh()
    }
}

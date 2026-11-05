// Deterministic answers to questions about the CURRENT state of the home
// ("how many lights are on?", "which fans are off?", "are any lamps on?").
// Pure: devices + a StateQuery in, spoken text out. Every count comes from
// code — a model (Jev) may at most pick the kind/state/aggregation of the
// question, never the number. Offline or never-read devices are left out of
// on/off counts and mentioned separately.
import Foundation

/// What a state question asks.
public struct StateQuery: Equatable, Hashable, Sendable {
    public enum State: String, CaseIterable, Sendable { case on, off, any }
    public enum Aggregation: String, CaseIterable, Sendable { case count, list, `is` }

    /// nil = every kind ("how many devices are on").
    public var kind: DeviceKind?
    public var state: State
    public var aggregation: Aggregation
    /// Extra words naming the devices ("study" in "which study lamps are on"),
    /// matched against each device's name, room and group.
    public var name: String?

    public init(kind: DeviceKind?, state: State, aggregation: Aggregation, name: String? = nil) {
        self.kind = kind
        self.state = state
        self.aggregation = aggregation
        self.name = name
    }
}

public enum DeviceQueryAnswerer {
    // allow-hardcode: spoken English answer templates (UI copy, not thresholds).
    /// Spoken answer; names are listed up to `listMax`, then "and N more".
    public static func answer(_ query: StateQuery, devices: [DeviceSummary],
                              listMax: Int = AppSettings.defaultStateQueryListMax) -> String {
        let pool = devices.filter { matches($0, query) }
        let noun = Noun(kind: query.kind)
        guard !pool.isEmpty else { return "No \(noun.plural) found\(scopePhrase(query))." }

        let offline = pool.filter { $0.reachability == .offline }
        let unknown = pool.filter { $0.reachability != .offline && $0.isOn == nil }
        let counted = pool.filter { $0.reachability != .offline && $0.isOn != nil }
        let hits = counted.filter { query.state == .any || $0.isOn == (query.state == .on) }
        let names = labelList(hits, max: listMax)
        let scope = scopePhrase(query)

        var text: String
        switch (query.aggregation, query.state) {
        case (_, .any):
            // "how many lights (are there)": the whole pool, reachable or not.
            return "\(countPhrase(pool.count, noun))\(scope): \(labelList(pool, max: listMax))."
        case (.count, _):
            if hits.isEmpty {
                text = "No \(noun.plural)\(scope) are \(query.state.rawValue)."
            } else {
                text = "\(hits.count) of \(counted.count) \(noun.form(counted.count))\(scope) \(verb(hits.count)) \(query.state.rawValue): \(names)."
            }
        case (.list, _):
            text = hits.isEmpty ? "No \(noun.plural)\(scope) are \(query.state.rawValue)."
                : "\(countPhrase(hits.count, noun))\(scope) \(verb(hits.count)) \(query.state.rawValue): \(names)."
        case (.is, _):
            text = hits.isEmpty ? "No, no \(noun.plural)\(scope) are \(query.state.rawValue)."
                : "Yes, \(countPhrase(hits.count, noun))\(scope) \(verb(hits.count)) \(query.state.rawValue): \(names)."
        }
        if !offline.isEmpty { text += " \(countPhrase(offline.count, noun)) \(verb(offline.count)) offline." }
        if !unknown.isEmpty { text += " \(countPhrase(unknown.count, noun)) \(unknown.count == 1 ? "has" : "have") no state reading yet." }
        return text
    }

    // MARK: - Matching

    static func matches(_ device: DeviceSummary, _ query: StateQuery) -> Bool {
        if let kind = query.kind, device.kind != kind { return false }
        guard let name = query.name, !name.isEmpty else { return true }
        let own = Set(TextNormalizer.tokens([device.name, device.room, device.group ?? ""].joined(separator: " ")))
        return TextNormalizer.tokens(name).allSatisfy(own.contains)
    }

    // MARK: - Phrasing

    // allow-hardcode: spoken English nouns for device kinds (the rawValues
    // read badly for climate / unknown); not thresholds.
    struct Noun {
        let singular: String
        init(kind: DeviceKind?) {
            switch kind {
            case .none, .some(.unknown): singular = "device"
            case .some(.climate): singular = "climate device"
            case .some(let kind): singular = kind.rawValue
            }
        }
        var plural: String { CommandPhrasing.plural(singular) }
        func form(_ count: Int) -> String { count == 1 ? singular : plural }
    }

    static func countPhrase(_ count: Int, _ noun: Noun) -> String { "\(count) \(noun.form(count))" }

    static func verb(_ count: Int) -> String { count == 1 ? "is" : "are" }

    static func scopePhrase(_ query: StateQuery) -> String {
        guard let name = query.name, !name.isEmpty else { return "" }
        return " matching \u{201C}\(name)\u{201D}"
    }

    /// A speakable label per device: its group when it has one (several
    /// lights share the name "study room"; their groups tell them apart),
    /// otherwise its name.
    static func label(_ device: DeviceSummary) -> String {
        if let group = device.group?.trimmingCharacters(in: .whitespaces), !group.isEmpty { return group }
        return device.name
    }

    /// Devices sharing a label are spoken once with a count ("study room
    /// middle (2)"); past `max` labels the rest are "N more" devices.
    static func labelList(_ devices: [DeviceSummary], max: Int) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for device in devices {
            let key = label(device)
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let limit = Swift.max(1, max)
        let spoken = order.prefix(limit).map { key -> String in
            let n = counts[key] ?? 1
            return n > 1 ? "\(key) (\(n))" : key
        }
        let rest = order.dropFirst(limit).reduce(0) { $0 + (counts[$1] ?? 0) }
        return CommandPhrasing.list(rest > 0 ? spoken + ["\(rest) more"] : spoken, conjunction: "and")
    }

    /// "A, B and C" — or "A, B and 3 more" past `max`.
    static func list(_ names: [String], max: Int) -> String {
        let limit = Swift.max(1, max)
        guard names.count > limit else { return CommandPhrasing.list(names, conjunction: "and") }
        return CommandPhrasing.list(Array(names.prefix(limit)) + ["\(names.count - limit) more"], conjunction: "and")
    }
}

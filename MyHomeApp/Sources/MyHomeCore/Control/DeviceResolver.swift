// Unified device-control API — device resolution.
//
// General rule: AMBIGUITY IS SURFACED, NEVER GUESSED. A query that several
// devices satisfy equally well returns `.ambiguous` with the candidates so the
// caller can ask; only an exact name, a lone match, or an explicit set request
// ("all the lights", a room, a group) resolves on its own.
import Foundation

/// What the caller knows about the target. All fields optional; `text` is the
/// free-form device phrase ("bedroom lights", "study fan").
public struct DeviceQuery: Equatable, Hashable, Sendable {
    public var text: String?
    public var room: String?
    public var group: String?
    public var kind: DeviceKind?
    /// Plural / "all": the caller wants every matching device.
    public var wantsSet: Bool
    /// Only devices that can perform this capability are considered.
    public var requiredCapability: SemanticCapability?
    /// Explicit ids (Shortcuts entities, model proposals): bypasses text matching.
    public var ids: [String]?
    /// Commands only: when the best matches mix devices with and without a
    /// control path, drop the unreachable ones so a namesake never shadows a
    /// reachable device. Status queries leave this off.
    public var preferControllable: Bool

    public init(text: String? = nil, room: String? = nil, group: String? = nil, kind: DeviceKind? = nil,
                wantsSet: Bool = false, requiredCapability: SemanticCapability? = nil, ids: [String]? = nil,
                preferControllable: Bool = false) {
        self.preferControllable = preferControllable
        self.text = text
        self.room = room
        self.group = group
        self.kind = kind
        self.wantsSet = wantsSet
        self.requiredCapability = requiredCapability
        self.ids = ids
    }

    public var isEmpty: Bool {
        (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty && room == nil && group == nil
            && kind == nil && (ids ?? []).isEmpty && !wantsSet
    }
}

public enum ResolutionScope: Equatable, Hashable, Sendable {
    case room(String)
    case group(String)
    case kind(DeviceKind)
    case all
}

public enum Resolution: Equatable {
    case none
    case single(Device)
    case set([Device], scope: ResolutionScope)
    case ambiguous([Device])
    /// Every member of one Briturn group: routed to the group write.
    case briturnGroup(String, members: [Device])

    public var devices: [Device] {
        switch self {
        case .none: return []
        case .single(let device): return [device]
        case .set(let devices, _): return devices
        case .ambiguous(let devices): return devices
        case .briturnGroup(_, let members): return members
        }
    }

    public var isAmbiguous: Bool {
        if case .ambiguous = self { return true }
        return false
    }
}

/// Scoring weights and thresholds (overridable through AppSettings).
public struct ResolverConfig: Equatable, Sendable {
    public var nameWeight: Double
    public var roomWeight: Double
    public var groupWeight: Double
    public var kindWeight: Double
    public var exactNameBonus: Double
    /// Candidates within this score distance of the best are "equally good".
    public var ambiguityMargin: Double
    /// Minimum fraction of query tokens that must match for a relaxed hit.
    public var minCoverage: Double

    public init(nameWeight: Double = 1.0, roomWeight: Double = 0.9, groupWeight: Double = 0.9, kindWeight: Double = 0.8,
                exactNameBonus: Double = 0.5, ambiguityMargin: Double = AppSettings.defaultResolverAmbiguityMargin,
                minCoverage: Double = AppSettings.defaultResolverMinCoverage) {
        self.nameWeight = nameWeight
        self.roomWeight = roomWeight
        self.groupWeight = groupWeight
        self.kindWeight = kindWeight
        self.exactNameBonus = exactNameBonus
        self.ambiguityMargin = ambiguityMargin
        self.minCoverage = minCoverage
    }
}

/// Words the resolver understands beyond device names. Kind synonyms map a
/// spoken noun to a DeviceKind; stop words are dropped before matching.
public struct ResolverVocabulary: Sendable {
    public var kindSynonyms: [String: DeviceKind]
    public var stopWords: Set<String>
    /// Words meaning "every matching device".
    public var setWords: Set<String>

    public init(kindSynonyms: [String: DeviceKind], stopWords: Set<String>, setWords: Set<String>) {
        self.kindSynonyms = kindSynonyms
        self.stopWords = stopWords
        self.setWords = setWords
    }

    // allow-hardcode: vocabulary of spoken device nouns and function words
    // (synonym table, not a matching oracle); every DeviceKind label is added
    // programmatically so new kinds are covered without editing this list.
    public static let standard: ResolverVocabulary = {
        var synonyms: [String: DeviceKind] = [
            "lamp": .light, "bulb": .light, "led": .light,
            "blind": .curtain, "shade": .curtain, "cover": .curtain,
            "socket": .plug, "outlet": .plug, "switch": .plug,
            "thermostat": .climate, "aircon": .climate, "ac": .climate, "heater": .climate,
            "filter": .purifier,
        ]
        for kind in [DeviceKind.fan, .curtain, .light, .plug, .climate, .purifier, .kettle] {
            synonyms[TextNormalizer.singular(TextNormalizer.fold(kind.label))] = kind
            synonyms[kind.rawValue] = kind
        }
        return ResolverVocabulary(
            synonyms: synonyms,
            stopWords: ["the", "a", "an", "my", "our", "this", "that", "please", "in", "at", "of", "to", "for"],
            setWords: ["all", "every", "everything", "each"]
        )
    }()

    private init(synonyms: [String: DeviceKind], stopWords: Set<String>, setWords: Set<String>) {
        self.init(kindSynonyms: synonyms, stopWords: stopWords, setWords: setWords)
    }

    public func kind(for token: String) -> DeviceKind? {
        kindSynonyms[token] ?? kindSynonyms[TextNormalizer.singular(token)]
    }

    public func tokens(for kind: DeviceKind) -> Set<String> {
        Set(kindSynonyms.filter { $0.value == kind }.map(\.key))
    }
}

public struct DeviceResolver {
    public let devices: [Device]
    public let config: ResolverConfig
    public let vocabulary: ResolverVocabulary
    /// Capability filter (the controller passes CapabilityMap through the store).
    public let supports: (Device, SemanticCapability) -> Bool
    /// Whether any control path (LAN, Bluetooth, cloud) exists for the device.
    public let isControllable: (Device) -> Bool

    public init(devices: [Device], config: ResolverConfig = ResolverConfig(),
                vocabulary: ResolverVocabulary = .standard,
                supports: @escaping (Device, SemanticCapability) -> Bool = { _, _ in true },
                isControllable: @escaping (Device) -> Bool = { _ in true }) {
        self.isControllable = isControllable
        self.devices = devices
        self.config = config
        self.vocabulary = vocabulary
        self.supports = supports
    }

    // MARK: - Scoring

    struct Match {
        let device: Device
        let score: Double
        let coverage: Double
        /// At least one query token matched the device NAME (not just room/kind/group).
        let nameSpecific: Bool
        let exactName: Bool
        let matchedRoom: Bool
        let matchedGroup: Bool
        let matchedKind: DeviceKind?
    }

    private func score(_ device: Device, queryTokens: [String], canonicalQuery: String) -> Match {
        let nameTokens = Set(TextNormalizer.tokens(device.name))
        let roomTokens = Set(TextNormalizer.tokens(device.room, stopWords: vocabulary.stopWords))
        let groupTokens = Set(TextNormalizer.tokens(device.group ?? "", stopWords: vocabulary.stopWords))
        let kindTokens = vocabulary.tokens(for: device.kind)
        let exact = !canonicalQuery.isEmpty && TextNormalizer.canonical(device.name) == canonicalQuery

        var total = 0.0
        var matched = 0
        var nameSpecific = false
        var matchedRoom = false
        var matchedGroup = false
        var matchedKind: DeviceKind?
        for token in queryTokens {
            var best = 0.0
            // Every source that explains the token is recorded (it decides the
            // set's scope); the highest weight decides the score.
            if nameTokens.contains(token) { best = config.nameWeight; nameSpecific = true }
            if groupTokens.contains(token) { best = max(best, config.groupWeight); matchedGroup = true }
            if roomTokens.contains(token) { best = max(best, config.roomWeight); matchedRoom = true }
            if kindTokens.contains(token) { best = max(best, config.kindWeight); matchedKind = device.kind }
            if best > 0 {
                matched += 1
                total += best
            }
        }
        let count = max(queryTokens.count, 1)
        var score = queryTokens.isEmpty ? 1.0 : total / Double(count)
        if exact { score += config.exactNameBonus }
        return Match(device: device, score: score, coverage: queryTokens.isEmpty ? 1 : Double(matched) / Double(count),
                     nameSpecific: nameSpecific || exact, exactName: exact,
                     matchedRoom: matchedRoom, matchedGroup: matchedGroup, matchedKind: matchedKind)
    }

    // MARK: - Resolution

    public func resolve(_ query: DeviceQuery) -> Resolution {
        resolveReporting(query).resolution
    }

    /// Like `resolve`, plus the matching devices that were set aside because
    /// they have no control path, so a caller can report them instead of
    /// letting a namesake vanish from the reply.
    public func resolveReporting(_ query: DeviceQuery) -> (resolution: Resolution, dropped: [Device]) {
        var dropped: [Device] = []
        let resolution = resolve(query, dropped: &dropped)
        return (resolution, dropped)
    }

    private func resolve(_ query: DeviceQuery, dropped: inout [Device]) -> Resolution {
        if let ids = query.ids, !ids.isEmpty {
            let wanted = Set(ids)
            let found = devices.filter { wanted.contains($0.id) && passesCapability($0, query) }
            if found.isEmpty { return .none }
            if found.count == 1 { return .single(found[0]) }
            return classifySet(found, query: query, scope: .all)
        }

        let rawTokens = TextNormalizer.rawTokens(query.text ?? "")
        let plural = rawTokens.contains { TextNormalizer.isPlural($0) && vocabulary.kind(for: $0) != nil }
        let wantsSet = query.wantsSet || plural || rawTokens.contains { vocabulary.setWords.contains($0) }
        let queryTokens = rawTokens.map(TextNormalizer.singular)
            .filter { !vocabulary.stopWords.contains($0) && !vocabulary.setWords.contains($0) }
        let canonicalQuery = queryTokens.joined(separator: " ")

        let filtered = devices.filter { passesFilters($0, query) }
        guard !filtered.isEmpty else { return .none }

        let matches = filtered.map { score($0, queryTokens: queryTokens, canonicalQuery: canonicalQuery) }
        var candidates = matches.filter { $0.coverage >= 1 }
        var relaxed = false
        if candidates.isEmpty {
            candidates = matches.filter { $0.coverage >= config.minCoverage && $0.coverage > 0 }
            relaxed = true
        }
        guard !candidates.isEmpty else { return .none }

        if query.preferControllable {
            let reachable = candidates.filter { isControllable($0.device) }
            if !reachable.isEmpty {
                dropped = candidates.filter { !isControllable($0.device) }.map(\.device)
                candidates = reachable
            }
        }

        if candidates.count == 1, !relaxed {
            return .single(candidates[0].device)
        }
        if relaxed {
            // Partial matches are suggestions, never a decision.
            return .ambiguous(candidates.sorted { $0.score > $1.score }.map(\.device))
        }

        let scope = inferredScope(candidates, query: query)
        if wantsSet {
            return classifySet(candidates.map(\.device), query: query, scope: scope)
        }
        let top = candidates.map(\.score).max() ?? 0
        let band = candidates.filter { $0.score >= top - config.ambiguityMargin }
        if band.count == 1 {
            return .single(band[0].device)
        }
        // A whole Briturn group named without a plural ("the study lights" vs
        // "the study group") still means the group when nothing else matched.
        if let group = briturnGroup(exactly: band.map(\.device)), band.allSatisfy({ $0.matchedGroup && !$0.nameSpecific }) {
            return .briturnGroup(group, members: band.map(\.device))
        }
        return .ambiguous(band.sorted { $0.score > $1.score }.map(\.device))
    }

    private func classifySet(_ found: [Device], query: DeviceQuery, scope: ResolutionScope) -> Resolution {
        if let group = briturnGroup(exactly: found) { return .briturnGroup(group, members: found) }
        return .set(found, scope: scope)
    }

    private func inferredScope(_ candidates: [Match], query: DeviceQuery) -> ResolutionScope {
        if let group = query.group { return .group(group) }
        if let room = query.room { return .room(room) }
        if candidates.allSatisfy(\.matchedGroup), let group = candidates.first?.device.group { return .group(group) }
        if candidates.allSatisfy(\.matchedRoom), let room = candidates.first?.device.room, !room.isEmpty { return .room(room) }
        if let kind = query.kind ?? candidates.first?.matchedKind, candidates.allSatisfy({ $0.device.kind == kind }) {
            return .kind(kind)
        }
        return .all
    }

    /// The group name when `found` is exactly the membership of one Briturn group.
    private func briturnGroup(exactly found: [Device]) -> String? {
        guard let group = found.first?.group, !group.isEmpty,
              found.allSatisfy({ $0.group == group && DeviceResolver.isBriturn($0) }) else { return nil }
        let members = devices.filter { DeviceResolver.isBriturn($0) && $0.group == group }
        return Set(members.map(\.id)) == Set(found.map(\.id)) ? group : nil
    }

    static func isBriturn(_ device: Device) -> Bool {
        device.category.lowercased() == "briturn"
    }

    private func passesFilters(_ device: Device, _ query: DeviceQuery) -> Bool {
        if let kind = query.kind, device.kind != kind { return false }
        if let room = query.room, !contains(device.room, phrase: room) { return false }
        if let group = query.group, !contains(device.group ?? "", phrase: group) { return false }
        return passesCapability(device, query)
    }

    private func passesCapability(_ device: Device, _ query: DeviceQuery) -> Bool {
        guard let capability = query.requiredCapability else { return true }
        return supports(device, capability)
    }

    /// Every token of `phrase` appears in `field` ("bedroom" ⊂ "Master Bedroom").
    private func contains(_ field: String, phrase: String) -> Bool {
        let fieldTokens = Set(TextNormalizer.tokens(field, stopWords: vocabulary.stopWords))
        let wanted = TextNormalizer.tokens(phrase, stopWords: vocabulary.stopWords)
        return !wanted.isEmpty && wanted.allSatisfy { fieldTokens.contains($0) }
    }
}

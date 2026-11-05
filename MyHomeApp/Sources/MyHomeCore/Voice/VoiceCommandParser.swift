// Level-1 (no model) command parser: a small deterministic grammar over
// tokens. It never guesses a device — it extracts the command and the
// device phrase, and DeviceResolver does the matching (and the asking).
import Foundation

/// What an utterance asked for.
public enum ParsedIntent: Equatable {
    case command(DeviceQuery, DeviceCommand)
    case status(DeviceQuery)
    case confirm
    case cancel
    case unknown(String)
}

/// Vocabulary of the rule-based grammar. Overridable so other languages or
/// house-specific phrasings can be supplied without touching the parser.
public struct CommandGrammar: Sendable {
    public var fillerPrefix: [String]
    public var powerVerbs: Set<String>
    public var onWords: Set<String>
    public var offWords: Set<String>
    public var openVerbs: Set<String>
    public var closeVerbs: Set<String>
    public var stopVerbs: Set<String>
    public var setVerbs: Set<String>
    /// Verbs that imply a brightness/level even with a bare number ("dim … to 5").
    public var levelVerbs: Set<String>
    public var levelNouns: Set<String>
    public var speedNouns: Set<String>
    public var modeNouns: Set<String>
    public var percentWords: Set<String>
    public var toWords: Set<String>
    public var roomPrepositions: Set<String>
    public var statusLeads: Set<String>
    public var confirmWords: Set<String>
    public var cancelWords: Set<String>
    /// Multi-word phrases map to a percent on the warm(0)…cool(100) scale.
    public var temperaturePhrases: [String: Int]
    public var colorNames: [String: RGB]
    /// A bare number up to this is a fan gear; above it, a percent.
    public var bareNumberGearMax: Int

    // allow-hardcode: this is the spoken-command grammar (verbs, particles,
    // colour names) — reviewed vocabulary, not a scoring oracle; it is
    // injectable so a different language can replace it wholesale.
    public static let standard = CommandGrammar(
        fillerPrefix: ["please", "hey", "ok", "okay", "can", "could", "would", "you", "myhome"],
        powerVerbs: ["turn", "switch", "power", "put", "flip", "toggle"],
        onWords: ["on", "enable", "activate"],
        offWords: ["off", "disable", "deactivate"],
        openVerbs: ["open", "raise"],
        closeVerbs: ["close", "shut", "lower"],
        stopVerbs: ["stop", "halt"],
        setVerbs: ["set", "make", "change", "adjust", "move"],
        levelVerbs: ["dim", "brighten"],
        levelNouns: ["brightness", "level", "position", "percent"],
        speedNouns: ["speed", "gear"],
        modeNouns: ["mode"],
        percentWords: ["percent", "pct"],
        toWords: ["to", "at"],
        roomPrepositions: ["in"],
        statusLeads: ["is", "are", "what", "whats", "how", "status", "state"],
        confirmWords: ["yes", "yeah", "yep", "sure", "confirm", "ok", "okay", "go", "ahead", "do", "it"],
        cancelWords: ["no", "nope", "cancel", "stop", "never", "mind", "forget", "it", "dont"],
        temperaturePhrases: ["warm white": 0, "warm": 0, "warmest": 0, "neutral": 50, "neutral white": 50,
                             "cool white": 100, "cool": 100, "cold white": 100, "daylight": 100, "coolest": 100],
        colorNames: ["red": RGB(red: 255, green: 0, blue: 0), "green": RGB(red: 0, green: 255, blue: 0),
                     "blue": RGB(red: 0, green: 0, blue: 255), "yellow": RGB(red: 255, green: 255, blue: 0),
                     "orange": RGB(red: 255, green: 128, blue: 0), "purple": RGB(red: 128, green: 0, blue: 255),
                     "pink": RGB(red: 255, green: 105, blue: 180), "cyan": RGB(red: 0, green: 255, blue: 255),
                     "white": RGB(red: 255, green: 255, blue: 255), "magenta": RGB(red: 255, green: 0, blue: 255)],
        bareNumberGearMax: DeviceState.numericFanSpeedMax
    )

    public init(fillerPrefix: [String], powerVerbs: Set<String>, onWords: Set<String>, offWords: Set<String>,
                openVerbs: Set<String>, closeVerbs: Set<String>, stopVerbs: Set<String>, setVerbs: Set<String>,
                levelVerbs: Set<String>, levelNouns: Set<String>, speedNouns: Set<String>, modeNouns: Set<String>,
                percentWords: Set<String>, toWords: Set<String>, roomPrepositions: Set<String>, statusLeads: Set<String>,
                confirmWords: Set<String>, cancelWords: Set<String>, temperaturePhrases: [String: Int],
                colorNames: [String: RGB], bareNumberGearMax: Int) {
        self.fillerPrefix = fillerPrefix
        self.powerVerbs = powerVerbs
        self.onWords = onWords
        self.offWords = offWords
        self.openVerbs = openVerbs
        self.closeVerbs = closeVerbs
        self.stopVerbs = stopVerbs
        self.setVerbs = setVerbs
        self.levelVerbs = levelVerbs
        self.levelNouns = levelNouns
        self.speedNouns = speedNouns
        self.modeNouns = modeNouns
        self.percentWords = percentWords
        self.toWords = toWords
        self.roomPrepositions = roomPrepositions
        self.statusLeads = statusLeads
        self.confirmWords = confirmWords
        self.cancelWords = cancelWords
        self.temperaturePhrases = temperaturePhrases
        self.colorNames = colorNames
        self.bareNumberGearMax = bareNumberGearMax
    }
}

public struct VoiceCommandParser {
    public let grammar: CommandGrammar
    public let vocabulary: ResolverVocabulary

    public init(grammar: CommandGrammar = .standard, vocabulary: ResolverVocabulary = .standard) {
        self.grammar = grammar
        self.vocabulary = vocabulary
    }

    public func parse(_ utterance: String) -> ParsedIntent {
        // "50%" → "50 percent" so the symbol survives tokenisation.
        let spaced = utterance.replacingOccurrences(of: "%", with: " percent ")
        var tokens = TextNormalizer.rawTokens(spaced)
        // Leading filler is dropped only when something follows it: "ok" alone
        // is a confirmation, "ok turn on the fan" is a command.
        while tokens.count > 1, let first = tokens.first, grammar.fillerPrefix.contains(first) { tokens.removeFirst() }
        guard !tokens.isEmpty else { return .unknown(utterance) }

        let content = tokens.filter { !vocabulary.stopWords.contains($0) }
        if !content.isEmpty, content.allSatisfy({ grammar.confirmWords.contains($0) }) { return .confirm }
        if !content.isEmpty, content.allSatisfy({ grammar.cancelWords.contains($0) }) { return .cancel }

        if grammar.statusLeads.contains(tokens[0]) {
            let rest = Array(tokens.dropFirst()).filter { !grammar.onWords.contains($0) && !grammar.offWords.contains($0) && !grammar.statusLeads.contains($0) }
            return .status(query(from: rest))
        }

        if let intent = parsePower(tokens) { return intent }
        if let intent = parseCover(tokens) { return intent }
        if let intent = parseSetting(tokens) { return intent }
        return .unknown(utterance)
    }

    // MARK: - Power

    private func parsePower(_ tokens: [String]) -> ParsedIntent? {
        let onIndex = tokens.firstIndex { grammar.onWords.contains($0) }
        let offIndex = tokens.firstIndex { grammar.offWords.contains($0) }
        guard onIndex != nil || offIndex != nil else { return nil }
        let hasVerb = grammar.powerVerbs.contains(tokens[0])
        let particleIndex = [onIndex, offIndex].compactMap { $0 }.min()!
        let particle = tokens[particleIndex]
        // The particle must follow the verb ("turn on X") or end the phrase
        // ("X on", "turn X on"); a mid-sentence "on" is a preposition
        // ("the light on the desk"), not a command.
        let atEnd = particleIndex == tokens.count - 1
        let afterVerb = hasVerb && particleIndex == 1
        guard afterVerb || atEnd else { return nil }
        let on = grammar.onWords.contains(particle)
        var rest = tokens
        rest.remove(at: particleIndex)
        if hasVerb { rest.removeFirst() }
        return .command(query(from: rest), .power(on))
    }

    // MARK: - Covers

    private func parseCover(_ tokens: [String]) -> ParsedIntent? {
        let verb = tokens[0]
        let action: CoverAction
        if grammar.openVerbs.contains(verb) { action = .open }
        else if grammar.closeVerbs.contains(verb) { action = .close }
        else if grammar.stopVerbs.contains(verb) { action = .stop }
        else { return nil }
        return .command(query(from: Array(tokens.dropFirst())), .cover(action))
    }

    // MARK: - Set …

    private func parseSetting(_ tokens: [String]) -> ParsedIntent? {
        var working = tokens
        let verb = working[0]
        let isSetVerb = grammar.setVerbs.contains(verb)
        let isLevelVerb = grammar.levelVerbs.contains(verb)
        if isSetVerb || isLevelVerb { working.removeFirst() }

        // Split at "to": left = target (+ nouns), right = value.
        var targetTokens = working
        var valueTokens: [String] = []
        if let to = working.firstIndex(where: { grammar.toWords.contains($0) }) {
            targetTokens = Array(working[..<to])
            valueTokens = Array(working[(to + 1)...])
        }
        let nounHints = Set(targetTokens.filter { grammar.levelNouns.contains($0) || grammar.speedNouns.contains($0) || grammar.modeNouns.contains($0) })
        targetTokens.removeAll { nounHints.contains($0) }

        var command: DeviceCommand?
        if valueTokens.isEmpty {
            // No "to": the value may sit inside the phrase ("fan speed 3",
            // "lamp warm white", "make the lamp red").
            if let (found, used) = valueFromPhrase(targetTokens, hints: nounHints, levelVerb: isLevelVerb) {
                command = found
                targetTokens.removeAll { used.contains($0) }
            }
        } else {
            command = value(valueTokens, hints: nounHints, levelVerb: isLevelVerb)
        }
        guard let command, !targetTokens.isEmpty || isSetVerb || isLevelVerb else { return nil }
        return .command(query(from: targetTokens), command)
    }

    private func value(_ tokens: [String], hints: Set<String>, levelVerb: Bool) -> DeviceCommand? {
        let phrase = tokens.joined(separator: " ")
        if let temperature = temperaturePhrase(in: phrase) { return .colorTemperature(temperature) }
        if let mode = modeValue(tokens, hints: hints) { return .mode(mode) }
        if let color = tokens.lazy.compactMap({ grammar.colorNames[$0] }).first { return .color(color) }
        guard let numberIndex = tokens.firstIndex(where: { Int($0) != nil }), let number = Int(tokens[numberIndex]) else { return nil }
        let isPercent = tokens.contains { grammar.percentWords.contains($0) }
        let speedHint = hints.contains { grammar.speedNouns.contains($0) } || tokens.contains { grammar.speedNouns.contains($0) }
        let levelHint = levelVerb || hints.contains { grammar.levelNouns.contains($0) }
        if isPercent { return .level(number) }
        if speedHint { return .fanSpeed(number) }
        if levelHint { return .level(number) }
        return number <= grammar.bareNumberGearMax ? .fanSpeed(number) : .level(number)
    }

    /// Values embedded in the target phrase; returns the command and the
    /// tokens it consumed.
    private func valueFromPhrase(_ tokens: [String], hints: Set<String>, levelVerb: Bool) -> (DeviceCommand, Set<String>)? {
        let phrase = tokens.joined(separator: " ")
        for (words, percent) in grammar.temperaturePhrases.sorted(by: { $0.key.count > $1.key.count })
            where phrase == words || phrase.hasSuffix(" " + words) || phrase.hasPrefix(words + " ") {
            return (.colorTemperature(percent), Set(words.split(separator: " ").map(String.init)))
        }
        if let colorToken = tokens.last, let color = grammar.colorNames[colorToken] {
            return (.color(color), [colorToken])
        }
        if let numberIndex = tokens.firstIndex(where: { Int($0) != nil }) {
            var consumed: Set<String> = [tokens[numberIndex]]
            let following = tokens.indices.contains(numberIndex + 1) ? tokens[numberIndex + 1] : ""
            if grammar.percentWords.contains(following) { consumed.insert(following) }
            let modeAfter = grammar.modeNouns.contains(following)
            let valueTokens = Array(tokens[numberIndex...])
            if modeAfter { return nil }
            guard let command = value(valueTokens, hints: hints, levelVerb: levelVerb) else { return nil }
            return (command, consumed)
        }
        if let mode = modeValue(tokens, hints: hints) {
            return (.mode(mode), [mode])
        }
        return nil
    }

    private func temperaturePhrase(in phrase: String) -> Int? {
        for (words, percent) in grammar.temperaturePhrases.sorted(by: { $0.key.count > $1.key.count }) {
            if phrase == words || phrase.hasPrefix(words + " ") || phrase.hasSuffix(" " + words) || phrase.contains(" \(words) ") {
                return percent
            }
        }
        return nil
    }

    /// "sleep mode", "mode sleep", or a bare word when the target carried a
    /// mode noun ("set fan mode to nature").
    private func modeValue(_ tokens: [String], hints: Set<String>) -> String? {
        if let index = tokens.firstIndex(where: { grammar.modeNouns.contains($0) }) {
            if index > 0 { return tokens[index - 1] }
            if tokens.indices.contains(index + 1) { return tokens[index + 1] }
            return nil
        }
        if hints.contains(where: { grammar.modeNouns.contains($0) }), tokens.count == 1, Int(tokens[0]) == nil {
            return tokens[0]
        }
        return nil
    }

    // MARK: - Target

    /// "lights in the bedroom" → text "lights", room "bedroom".
    func query(from tokens: [String]) -> DeviceQuery {
        var words = tokens
        var room: String?
        if let at = words.firstIndex(where: { grammar.roomPrepositions.contains($0) }), at < words.count - 1 {
            let roomWords = words[(at + 1)...].filter { !vocabulary.stopWords.contains($0) }
            if !roomWords.isEmpty { room = roomWords.joined(separator: " ") }
            words = Array(words[..<at])
        }
        let text = words.filter { !vocabulary.stopWords.contains($0) }.joined(separator: " ")
        return DeviceQuery(text: text, room: room)
    }
}

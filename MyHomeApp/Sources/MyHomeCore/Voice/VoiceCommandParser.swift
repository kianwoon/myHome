// Level-1 (no model) command parser: a small deterministic grammar over
// tokens. It never guesses a device — it extracts the command and the
// device phrase, and DeviceResolver does the matching (and the asking).
import Foundation

/// What an utterance asked for.
public enum ParsedIntent: Equatable {
    case command(DeviceQuery, DeviceCommand)
    case status(DeviceQuery)
    /// A count/list/yes-no question over many devices ("how many lights are on").
    case stateQuery(StateQuery)
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
    /// Spelled-out numbers ("two" → 2), valid anywhere a digit is.
    public var numberWords: [String: Int]
    /// Sound-alikes the recogniser produces for a number ("to 2" → "to do").
    /// Only trusted for the value of a speed/gear setting, where a word that is
    /// not a number cannot otherwise be a value.
    public var speedNumberHomophones: [String: Int]
    /// Multipliers for spelled-out numbers ("one hundred" → 100).
    public var numberScaleWords: [String: Int]
    /// Spelled numbers at or below this stay words unless part of a longer
    /// run, so "the desk one" still names a device (see valueFromPhrase).
    public var spelledNumberWordMax: Int
    /// Leads of a question over many devices → how to answer it.
    public var stateQueryLeads: [String: StateQuery.Aggregation]
    /// Words that mean "on" in a state question ("is the fan running").
    public var runningWords: Set<String>
    /// Nouns meaning "any kind of device" ("how many devices are on").
    public var anyKindWords: Set<String>
    /// Function words dropped from a state question's device phrase.
    public var stateQueryFillers: Set<String>

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
        bareNumberGearMax: DeviceState.numericFanSpeedMax,
        numberWords: ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                      "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
                      "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
                      "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
                      "eighty": 80, "ninety": 90],
        speedNumberHomophones: ["do": 2, "too": 2, "tu": 2, "for": 4],
        numberScaleWords: ["hundred": 100],
        spelledNumberWordMax: 10,
        stateQueryLeads: ["how many": .count, "which": .list, "what": .list, "list": .list,
                          "are any": .is, "is any": .is, "are there any": .is, "is there any": .is],
        runningWords: ["running", "lit"],
        anyKindWords: ["device", "thing", "appliance"],
        stateQueryFillers: ["are", "is", "there", "do", "does", "i", "we", "have", "currently", "right", "now",
                            "turned", "switched", "that", "still", "got", "left", "any"]
    )

    public init(fillerPrefix: [String], powerVerbs: Set<String>, onWords: Set<String>, offWords: Set<String>,
                openVerbs: Set<String>, closeVerbs: Set<String>, stopVerbs: Set<String>, setVerbs: Set<String>,
                levelVerbs: Set<String>, levelNouns: Set<String>, speedNouns: Set<String>, modeNouns: Set<String>,
                percentWords: Set<String>, toWords: Set<String>, roomPrepositions: Set<String>, statusLeads: Set<String>,
                confirmWords: Set<String>, cancelWords: Set<String>, temperaturePhrases: [String: Int],
                colorNames: [String: RGB], bareNumberGearMax: Int,
                numberWords: [String: Int] = [:], speedNumberHomophones: [String: Int] = [:],
                numberScaleWords: [String: Int] = [:], spelledNumberWordMax: Int = 10,
                stateQueryLeads: [String: StateQuery.Aggregation] = [:], runningWords: Set<String> = [],
                anyKindWords: Set<String> = [], stateQueryFillers: Set<String> = []) {
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
        self.numberWords = numberWords
        self.speedNumberHomophones = speedNumberHomophones
        self.numberScaleWords = numberScaleWords
        self.spelledNumberWordMax = spelledNumberWordMax
        self.stateQueryLeads = stateQueryLeads
        self.runningWords = runningWords
        self.anyKindWords = anyKindWords
        self.stateQueryFillers = stateQueryFillers
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
        var tokens = mergeSpelledNumbers(splitGluedValues(TextNormalizer.rawTokens(spaced)))
        // Leading filler is dropped only when something follows it: "ok" alone
        // is a confirmation, "ok turn on the fan" is a command.
        while tokens.count > 1, let first = tokens.first, grammar.fillerPrefix.contains(first) { tokens.removeFirst() }
        guard !tokens.isEmpty else { return .unknown(utterance) }

        let content = tokens.filter { !vocabulary.stopWords.contains($0) }
        if !content.isEmpty, content.allSatisfy({ grammar.confirmWords.contains($0) }) { return .confirm }
        if !content.isEmpty, content.allSatisfy({ grammar.cancelWords.contains($0) }) { return .cancel }

        // Before the status branch: "how many lights are on" is a question
        // over a kind of device, not the status of one named device.
        if let intent = parseStateQuery(tokens) { return intent }

        if grammar.statusLeads.contains(tokens[0]) {
            let rest = Array(tokens.dropFirst()).filter {
                !grammar.onWords.contains($0) && !grammar.offWords.contains($0) && !grammar.statusLeads.contains($0) && !grammar.runningWords.contains($0)
            }
            return .status(query(from: rest))
        }

        if let intent = parsePower(tokens) { return intent }
        if let intent = parseCover(tokens) { return intent }
        if let intent = parseSetting(tokens) { return intent }
        return .unknown(utterance)
    }

    /// The numeric value a request carries ("to 40", "speed two", "50%"), read
    /// with the same normalisation as `parse`: the number after a value
    /// particle ("to"/"at") when there is one, else the last number. Used when
    /// a classifier chose the action; the value itself is never guessed.
    public func value(in utterance: String) -> Int? {
        let spaced = utterance.replacingOccurrences(of: "%", with: " percent ")
        let tokens = mergeSpelledNumbers(splitGluedValues(TextNormalizer.rawTokens(spaced)))
        for (index, token) in tokens.enumerated() where grammar.toWords.contains(token) && index + 1 < tokens.count {
            if let number = Int(tokens[index + 1]) { return number }
        }
        return tokens.compactMap { Int($0) }.last
    }

    // MARK: - State questions

    /// "<lead> … <kind noun> … [on|off|running]": a count / list / yes-no
    /// question over a kind of device. Needs a kind noun (or "devices"), and
    /// an on/off word unless it counts ("how many lights are there").
    private func parseStateQuery(_ tokens: [String]) -> ParsedIntent? {
        let leads = grammar.stateQueryLeads.sorted { $0.key.count > $1.key.count }
        for (lead, aggregation) in leads {
            let words = lead.split(separator: " ").map(String.init)
            guard tokens.count > words.count, Array(tokens.prefix(words.count)) == words else { continue }
            let rest = Array(tokens.dropFirst(words.count))
            let anyKind: (Int) -> Bool = { grammar.anyKindWords.contains(TextNormalizer.singular(rest[$0])) }
            guard let kindIndex = rest.indices.first(where: { vocabulary.kind(for: rest[$0]) != nil || anyKind($0) }) else { return nil }
            let kind = anyKind(kindIndex) ? nil : vocabulary.kind(for: rest[kindIndex])
            let on = rest.contains { grammar.onWords.contains($0) || grammar.runningWords.contains($0) }
            let off = rest.contains { grammar.offWords.contains($0) }
            let state: StateQuery.State = on == off ? .any : (on ? .on : .off)
            guard state != .any || aggregation == .count else { return nil }
            let nameWords = rest.enumerated().filter { index, word in
                index != kindIndex && !vocabulary.stopWords.contains(word) && !grammar.onWords.contains(word)
                    && !grammar.offWords.contains(word) && !grammar.runningWords.contains(word)
                    && !grammar.statusLeads.contains(word) && !grammar.stateQueryFillers.contains(word)
            }.map(\.element)
            let name = nameWords.joined(separator: " ")
            return .stateQuery(StateQuery(kind: kind, state: state, aggregation: aggregation, name: name.isEmpty ? nil : name))
        }
        return nil
    }

    // MARK: - Recogniser artefacts

    /// SenseVoice's inverse text normalisation glues a digit onto "to"
    /// ("speed to2"); split only a value particle followed by digits, never a
    /// device name like "8e6d".
    private func splitGluedValues(_ tokens: [String]) -> [String] {
        tokens.flatMap { token -> [String] in
            for word in grammar.toWords where token.count > word.count && token.hasPrefix(word) {
                let rest = String(token.dropFirst(word.count))
                if Int(rest) != nil { return [word, rest] }
            }
            return [token]
        }
    }

    /// Qwen3-ASR spells numbers out ("fifty percent", "twenty five"). A run of
    /// number words becomes digits when it is compound or above
    /// `spelledNumberWordMax`; a lone small word ("one") is left alone.
    private func mergeSpelledNumbers(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            var total = 0, current = 0, end = index
            while end < tokens.count {
                if let value = grammar.numberWords[tokens[end]] {
                    // "twenty five" adds; "five five" does not compound.
                    if current > 0, !(current % 10 == 0 && current >= 20 && value < 10) { break }
                    current += value
                } else if let scale = grammar.numberScaleWords[tokens[end]], end > index {
                    current = max(current, 1) * scale
                    total += current
                    current = 0
                } else {
                    break
                }
                end += 1
            }
            let run = end - index
            let value = total + current
            if run > 1 || (run == 1 && value > grammar.spelledNumberWordMax) {
                out.append(String(value))
                index = end
            } else {
                out.append(tokens[index])
                index += 1
            }
        }
        return out
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
        // A leading particle ("off the study fan") is a command whose verb the
        // recogniser clipped (the mic opened a moment after the user spoke).
        let leading = particleIndex == 0 && tokens.count > 1
        guard afterVerb || atEnd || leading else { return nil }
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
        let speedHint = hints.contains { grammar.speedNouns.contains($0) } || tokens.contains { grammar.speedNouns.contains($0) }
        guard let number = numberValue(in: tokens, allowHomophones: speedHint) else { return nil }
        let isPercent = tokens.contains { grammar.percentWords.contains($0) }
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
        // A spelled-out number only counts when a setting noun introduced it
        // ("fan speed three"); "the desk one" names a device, not a value.
        let spelledOK = !hints.isEmpty
        if let numberIndex = tokens.firstIndex(where: { Int($0) != nil || (spelledOK && grammar.numberWords[$0] != nil) }) {
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

    /// A digit string or a spelled-out number.
    private func number(from token: String) -> Int? {
        Int(token) ?? grammar.numberWords[token]
    }

    /// The value of a setting: the first number, else (speed settings only,
    /// where the value is a lone word) a recogniser sound-alike of one.
    private func numberValue(in tokens: [String], allowHomophones: Bool) -> Int? {
        if let found = tokens.lazy.compactMap({ number(from: $0) }).first { return found }
        let words = tokens.filter { !vocabulary.stopWords.contains($0) && !grammar.percentWords.contains($0) }
        if allowHomophones, words.count == 1 { return grammar.speedNumberHomophones[words[0]] }
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
        if hints.contains(where: { grammar.modeNouns.contains($0) }), tokens.count == 1, number(from: tokens[0]) == nil {
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

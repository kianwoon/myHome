// The wake word's model side: install location + usability gate, download,
// phrase → phone-token encoding (English lexicon), and the sherpa-onnx
// keyword spotter behind the `WakeWordSpotting` protocol. sherpa-onnx crashes
// on a bad asset or an unknown token, so nothing here constructs a spotter
// before the files AND the encoded phrase were validated.
import Foundation
import SherpaOnnx
import SherpaOnnxC

// MARK: - Store

public enum WakeWordModelStore {
    /// `~/Library/Application Support/MyHome/speech/kws`.
    public static var directory: URL {
        SpeechModelStore.applicationSupport
            .appendingPathComponent(SpeechModelSpec.appSupportFolder, isDirectory: true)
            .appendingPathComponent(SpeechModelSpec.speechFolder, isDirectory: true)
            .appendingPathComponent(WakeWordModelSpec.directoryName, isDirectory: true)
    }

    static func url(_ name: String, in dir: URL) -> URL { dir.appendingPathComponent(name) }

    /// Size floors + ONNX header + a parseable token table.
    public static func isInstalled(at dir: URL = directory) -> Bool {
        let checks: [(String, Int, Bool)] = [
            (WakeWordModelSpec.encoderFile, WakeWordModelSpec.minEncoderBytes, true),
            (WakeWordModelSpec.decoderFile, WakeWordModelSpec.minDecoderBytes, true),
            (WakeWordModelSpec.joinerFile, WakeWordModelSpec.minJoinerBytes, true),
            (WakeWordModelSpec.tokensFile, WakeWordModelSpec.minTokensBytes, false),
            (WakeWordModelSpec.lexiconFile, WakeWordModelSpec.minLexiconBytes, false)
        ]
        for (name, floor, onnx) in checks {
            let path = url(name, in: dir).path
            guard SpeechModelStore.fileSize(path) >= floor else { return false }
            if onnx, !SpeechModelStore.onnxHeaderLooksValid(path) { return false }
        }
        guard let tokens = try? String(contentsOf: url(WakeWordModelSpec.tokensFile, in: dir), encoding: .utf8) else { return false }
        return SpeechModelStore.tokensParseable(tokens)
    }
}

// MARK: - Install

public actor WakeWordModelInstaller {
    public static let shared = WakeWordModelInstaller()
    private var inFlight: Task<Void, Error>?

    public func install() async throws {
        if let existing = inFlight { return try await existing.value }
        let task = Task<Void, Error> { try await Self.download() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    static func download(into dir: URL = WakeWordModelStore.directory) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let archiveURL = URL(string: "\(WakeWordModelSpec.releaseBaseURL)/\(WakeWordModelSpec.archiveName).\(WakeWordModelSpec.archiveExtension)") else {
            throw SpeechModelInstallError.badURL
        }
        AppLog.assistant.info("wake model download start")
        let (location, response) = try await URLSession.shared.download(from: archiveURL)
        defer { try? fm.removeItem(at: location) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SpeechModelInstallError.httpStatus(http.statusCode)
        }
        let staging = dir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: SpeechModelSpec.tarPath)
        tar.arguments = ["-xjf", location.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw SpeechModelInstallError.extract(tar.terminationStatus) }
        var found: [String: URL] = [:]
        if let walker = fm.enumerator(at: staging, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { found[url.lastPathComponent] = found[url.lastPathComponent] ?? url }
        }
        let names = [WakeWordModelSpec.encoderFile, WakeWordModelSpec.decoderFile, WakeWordModelSpec.joinerFile,
                     WakeWordModelSpec.tokensFile, WakeWordModelSpec.lexiconFile]
        for name in names {
            guard let source = found[name] else { throw SpeechModelInstallError.missingFiles }
            let destination = WakeWordModelStore.url(name, in: dir)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: source, to: destination)
        }
        guard WakeWordModelStore.isInstalled(at: dir) else { throw SpeechModelInstallError.missingFiles }
        AppLog.assistant.info("wake model download done")
    }
}

// MARK: - Phrase encoding

public enum WakeWordPhraseError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknownWord(String)
    case unknownToken(String)
    case unknownSyllable(String)
    case unreadable

    public var description: String {
        switch self {
        case .empty: return "The wake phrase is empty."
        case .unknownWord(let word): return "\"\(word)\" is not in the wake-word dictionary. Use common English words, Chinese characters or pinyin (hēi / hei1)."
        case .unknownToken(let token): return "The wake-word model does not know the sound \"\(token)\"."
        case .unknownSyllable(let syllable): return "\"\(syllable)\" is not a pinyin syllable the model knows. Type the pinyin with its tone, e.g. hēi or hei1."
        case .unreadable: return "The wake-word model files could not be read."
        }
    }
}

public enum WakeWordPhraseEncoder {
    /// One piece of a phrase: an English word (lexicon lookup) or a pinyin
    /// syllable (from a Chinese character or typed by the user).
    public enum Segment: Equatable {
        case english(String)
        case pinyin(String)
    }

    /// "Hey 小家", "hēi hǒu", "hei1 hou3", "嘿home" — whitespace-separated words,
    /// each split further into Chinese-character runs and the rest.
    public static func segments(of phrase: String) -> [Segment] {
        var out: [Segment] = []
        let keepApostrophe = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'"))
        func flushLatin(_ text: String) {
            let word = text.trimmingCharacters(in: keepApostrophe)
            guard !word.isEmpty else { return }
            if WakeWordPinyin.looksLikePinyin(word) {
                out.append(.pinyin(WakeWordPinyin.applyToneNumber(word)))
            } else {
                out.append(.english(word.uppercased()))
            }
        }
        var latin = "", han = ""
        func flush() {
            flushLatin(latin); latin = ""
            if !han.isEmpty { out += WakeWordPinyin.syllables(ofHan: han).map(Segment.pinyin); han = "" }
        }
        for c in phrase {
            if WakeWordPinyin.isHan(c) {
                if !latin.isEmpty { flush() }
                han.append(c)
            } else if c.isWhitespace || (c.isPunctuation && c != "'") {
                flush()   // separators, incl. Chinese punctuation
            } else {
                if !han.isEmpty { flush() }
                latin.append(c)
            }
        }
        flush()
        return out
    }

    /// Model units for `phrase`: English words through `lexicon` (`WORD PH1
    /// PH2 …`, first pronunciation wins), pinyin as initial + tone-marked
    /// final; every unit checked against `tokens` (sherpa-onnx crashes on an
    /// unknown token).
    public static func encode(_ phrase: String, lexicon: [String: [String]], tokens: Set<String>) throws -> [String] {
        let parts = segments(of: phrase)
        guard !parts.isEmpty else { throw WakeWordPhraseError.empty }
        var units: [String] = []
        for part in parts {
            switch part {
            case .english(let word):
                guard let pronunciation = lexicon[word] else { throw WakeWordPhraseError.unknownWord(word) }
                if let bad = pronunciation.first(where: { !tokens.contains($0) }) { throw WakeWordPhraseError.unknownToken(bad) }
                units += pronunciation
            case .pinyin(let syllable):
                let pieces = WakeWordPinyin.units(ofSyllable: syllable)
                guard pieces.allSatisfy(tokens.contains) else { throw WakeWordPhraseError.unknownSyllable(syllable) }
                units += pieces
            }
        }
        return units
    }

    /// Only the English words of `phrase` are kept (the lexicon has ~126k lines).
    public static func loadLexicon(at url: URL, for phrase: String) throws -> [String: [String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw WakeWordPhraseError.unreadable }
        let wanted = Set(segments(of: phrase).compactMap { segment -> String? in
            if case .english(let word) = segment { return word }
            return nil
        })
        var lexicon: [String: [String]] = [:]
        guard !wanted.isEmpty else { return lexicon }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, wanted.contains(parts[0]), lexicon[parts[0]] == nil else { continue }
            lexicon[parts[0]] = Array(parts.dropFirst())
        }
        return lexicon
    }

    public static func loadTokens(at url: URL) throws -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw WakeWordPhraseError.unreadable }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: " ").first.map(String.init) })
    }

    /// Validates `phrase` against the installed model; nil when usable.
    public static func validate(_ phrase: String, directory: URL = WakeWordModelStore.directory) -> String? {
        guard WakeWordModelStore.isInstalled(at: directory) else { return nil }   // checked again on install
        do {
            let lexicon = try loadLexicon(at: WakeWordModelStore.url(WakeWordModelSpec.lexiconFile, in: directory), for: phrase)
            _ = try encode(phrase, lexicon: lexicon,
                           tokens: loadTokens(at: WakeWordModelStore.url(WakeWordModelSpec.tokensFile, in: directory)))
            return nil
        } catch {
            return (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        }
    }

    /// One sherpa-onnx keywords line: tokens, `:boost`, `#threshold`, `@tag`.
    public static func keywordsLine(phones: [String], boost: Double, threshold: Double,
                                    tag: String = WakeWordModelSpec.keywordTag) -> String {
        "\(phones.joined(separator: " ")) :\(boost) #\(threshold) @\(tag)"
    }
}

// MARK: - Spotter

/// Streaming detector. NOT thread-safe: one caller (the listener's queue).
public protocol WakeWordSpotting: AnyObject {
    /// 16 kHz mono samples in; true when the wake phrase completed in them.
    func accept(_ samples: [Float]) -> Bool
    func reset()
}

final class SherpaWakeWordSpotter: WakeWordSpotting {
    private let spotter: SherpaOnnxKeywordSpotterWrapper

    struct Config {
        var phrase: String
        var boost: Double
        var threshold: Double
        /// Probe-only: raw keywords lines replacing the encoded phrase.
        var keywordsOverride: String? = nil
        var maxActivePaths = WakeWordModelSpec.maxActivePaths
        var numTrailingBlanks = WakeWordModelSpec.numTrailingBlanks
    }

    /// Validates files and phrase first; throws instead of letting sherpa crash.
    init(directory: URL = WakeWordModelStore.directory, config: Config) throws {
        guard WakeWordModelStore.isInstalled(at: directory) else { throw WakeWordPhraseError.unreadable }
        let tokensURL = WakeWordModelStore.url(WakeWordModelSpec.tokensFile, in: directory)
        let lexicon = try WakeWordPhraseEncoder.loadLexicon(at: WakeWordModelStore.url(WakeWordModelSpec.lexiconFile, in: directory),
                                                            for: config.phrase)
        let phones = try WakeWordPhraseEncoder.encode(config.phrase, lexicon: lexicon,
                                                      tokens: WakeWordPhraseEncoder.loadTokens(at: tokensURL))
        let keywords = config.keywordsOverride ?? WakeWordPhraseEncoder.keywordsLine(phones: phones, boost: config.boost, threshold: config.threshold)
        let model = sherpaOnnxOnlineModelConfig(
            tokens: tokensURL.path,
            transducer: sherpaOnnxOnlineTransducerModelConfig(
                encoder: WakeWordModelStore.url(WakeWordModelSpec.encoderFile, in: directory).path,
                decoder: WakeWordModelStore.url(WakeWordModelSpec.decoderFile, in: directory).path,
                joiner: WakeWordModelStore.url(WakeWordModelSpec.joinerFile, in: directory).path),
            numThreads: WakeWordModelSpec.inferenceThreads,
            provider: "cpu",
            debug: 0)
        var kws = sherpaOnnxKeywordSpotterConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: SpeechModelSpec.sampleRate, featureDim: SpeechModelSpec.featureDim),
            modelConfig: model,
            keywordsFile: "",
            maxActivePaths: config.maxActivePaths,
            numTrailingBlanks: config.numTrailingBlanks,
            keywordsScore: Float(config.boost),
            keywordsThreshold: Float(config.threshold),
            keywordsBuf: keywords,
            keywordsBufSize: keywords.utf8.count)
        spotter = SherpaOnnxKeywordSpotterWrapper(config: &kws)
        guard spotter.spotter != nil, spotter.stream != nil else { throw WakeWordPhraseError.unreadable }
    }

    func accept(_ samples: [Float]) -> Bool {
        spotter.acceptWaveform(samples: samples, sampleRate: SpeechModelSpec.sampleRate)
        var hit = false
        while spotter.isReady() {
            spotter.decode()
            if !spotter.getResult().keyword.isEmpty {
                hit = true
                freshStream()   // or it re-fires
            }
        }
        return hit
    }

    func reset() { freshStream() }

    /// A NEW stream, never `SherpaOnnxResetKeywordStream`: the reset keeps
    /// stale encoder state and detection decays with every reuse (measured:
    /// one real clip replayed 3× gave 2, 1, then 0 hits; a fresh stream keeps
    /// every pass at full sensitivity).
    private func freshStream() {
        let old = spotter.stream
        spotter.stream = SherpaOnnxCreateKeywordStream(spotter.spotter)
        if let old { SherpaOnnxDestroyOnlineStream(old) }
    }
}

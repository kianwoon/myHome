// Spoken replies via AVSpeechSynthesizer. Gated by the spokenReplies setting.
import Foundation
import AVFoundation
import NaturalLanguage

@MainActor
public final class SpeechResponder: ObservableObject {
    @Published public private(set) var isSpeaking: Bool = false

    private let defaults: UserDefaults
    private let synthesizer = AVSpeechSynthesizer()
    private let speechDelegate = Delegate()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        speechDelegate.owner = self
        synthesizer.delegate = speechDelegate
    }

    public func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppSettings.spokenRepliesEnabled(from: defaults), !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = true
        // One utterance per language run: a Chinese reply with an English
        // "Not done: ..." tail must not be read whole by a single voice.
        for part in Self.segments(of: trimmed) {
            let utterance = AVSpeechUtterance(string: part.text)
            utterance.voice = part.language.flatMap { AVSpeechSynthesisVoice(language: $0) } ?? localeVoice()
            synthesizer.speak(utterance)
        }
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Sentences grouped into runs of the same language, in order.
    nonisolated static func segments(of text: String) -> [(text: String, language: String?)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var runs: [(text: String, language: String?)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            let language = dominantLanguage(of: sentence)
            if let last = runs.last, last.language == language {
                runs[runs.count - 1].text += " " + sentence
            } else {
                runs.append((sentence, language))
            }
            return true
        }
        return runs.isEmpty ? [(text, dominantLanguage(of: text))] : runs
    }

    /// Languages the speech stack can actually hear (SenseVoice/Qwen: zh, en, ja, ko, yue) plus
    /// the owner's voice locale. Anything else is a misdetection of a short, garbled phrase
    /// ("De study role like to 40%" reads as Dutch) and must not pick the reply language.
    nonisolated static func plausibleLanguages(voiceLocale: Locale) -> [NLLanguage] {
        var languages: [NLLanguage] = [.english, .simplifiedChinese, .traditionalChinese, .japanese, .korean]
        if let code = voiceLocale.language.languageCode?.identifier {
            let own = NLLanguage(rawValue: code)
            if !languages.contains(own) { languages.append(own) }
        }
        return languages
    }

    nonisolated static func dominantLanguage(of text: String, voiceLocale: Locale = AppSettings.voiceLocale()) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = plausibleLanguages(voiceLocale: voiceLocale)
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    private func localeVoice() -> AVSpeechSynthesisVoice? {
        let locale = AppSettings.voiceLocale(from: defaults)
        if let voice = AVSpeechSynthesisVoice(language: locale.identifier) { return voice }
        if let code = locale.language.languageCode?.identifier {
            return AVSpeechSynthesisVoice(language: code)
        }
        return nil
    }

    fileprivate func speakingChanged(_ speaking: Bool) { isSpeaking = speaking }

    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        nonisolated(unsafe) weak var owner: SpeechResponder?

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            let stillSpeaking = synthesizer.isSpeaking
            Task { @MainActor in
                if let owner, !stillSpeaking { owner.speakingChanged(false) }
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            let stillSpeaking = synthesizer.isSpeaking
            Task { @MainActor in
                if let owner, !stillSpeaking { owner.speakingChanged(false) }
            }
        }
    }
}

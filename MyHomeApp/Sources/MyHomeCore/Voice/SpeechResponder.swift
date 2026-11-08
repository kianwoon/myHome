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
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice(for: trimmed)
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// The reply's own language wins (a Chinese reply read by an English voice
    /// is silent or garbled); the voice locale is the fallback.
    private func voice(for text: String) -> AVSpeechSynthesisVoice? {
        if let detected = Self.dominantLanguage(of: text), let match = AVSpeechSynthesisVoice(language: detected) {
            return match
        }
        return localeVoice()
    }

    nonisolated static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
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

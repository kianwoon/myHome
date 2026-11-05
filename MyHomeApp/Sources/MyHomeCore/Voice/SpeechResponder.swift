// Spoken replies via AVSpeechSynthesizer. Gated by the spokenReplies setting.
import Foundation
import AVFoundation

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
        utterance.voice = voice()
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func voice() -> AVSpeechSynthesisVoice? {
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

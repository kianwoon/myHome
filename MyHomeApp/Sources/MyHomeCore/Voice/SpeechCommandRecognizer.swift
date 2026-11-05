// Push-to-talk speech capture for the assistant. One listening session yields
// at most one utterance, delivered through `onUtterance`. All thresholds come
// from AppSettings; transcripts are never logged with public privacy.
import Foundation
import Speech
import AVFoundation
import os

@MainActor
public final class SpeechCommandRecognizer: ObservableObject {
    public enum Status: Equatable {
        case idle, requestingPermission, listening, unavailable(String)
    }

    public enum Authorization: Equatable {
        case authorized, denied(String), notDetermined
    }

    public static let microphoneUsageKey = "NSMicrophoneUsageDescription"
    public static let speechUsageKey = "NSSpeechRecognitionUsageDescription"
    /// Audio tap buffer size in frames.
    nonisolated static let tapBufferSize: AVAudioFrameCount = 1024

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var transcript: String = ""
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var usesOnDeviceRecognition: Bool = false
    /// Usage keys present AND a recogniser exists for the configured locale.
    /// Stored (not computed) because the command bar reads it on every body
    /// evaluation; refreshed at init and whenever listening starts.
    @Published public private(set) var isSupported: Bool = false

    /// Called once per session with the trimmed, non-empty final transcript.
    public var onUtterance: ((String) -> Void)?

    private let defaults: UserDefaults
    private let bundle: Bundle
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var maxTimer: Task<Void, Never>?
    private var delivered = false
    private var session = 0
    private var starting = false

    public init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        refreshSupport()
    }

    public static func usageDescriptionsPresent(in bundle: Bundle) -> Bool {
        let info = bundle.infoDictionary ?? [:]
        return info[microphoneUsageKey] != nil && info[speechUsageKey] != nil
    }

    /// Re-evaluates `isSupported` (e.g. after the voice locale setting changed).
    /// Without the usage keys no recogniser is created at all.
    public func refreshSupport() {
        guard Self.usageDescriptionsPresent(in: bundle),
              let recognizer = SFSpeechRecognizer(locale: AppSettings.voiceLocale(from: defaults)) else {
            isSupported = false
            return
        }
        isSupported = recognizer.isAvailable
    }

    // MARK: Authorization

    public func requestAuthorization() async -> Authorization {
        guard Self.usageDescriptionsPresent(in: bundle) else {
            return .denied("This app bundle lacks microphone and speech usage descriptions; use the Xcode-built app.")
        }
        let speech = await Self.requestSpeechAuthorization()
        switch speech {
        case .authorized: break
        case .denied: return .denied("Speech recognition permission was denied.")
        case .restricted: return .denied("Speech recognition is restricted on this Mac.")
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
        let micGranted = await Self.requestMicrophoneAccess()
        return micGranted ? .authorized : .denied("Microphone permission was denied.")
    }

    // The system invokes these callbacks on arbitrary queues, so they are
    // built outside the main actor (like installTap / startTask below).
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private nonisolated static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Listening

    public func startListening() {
        guard !isListening, !starting else { return }
        refreshSupport()
        starting = true
        status = .requestingPermission
        lastError = nil
        Task { @MainActor in
            let auth = await requestAuthorization()
            starting = false
            switch auth {
            case .authorized: beginSession()
            case .denied(let reason):
                status = .unavailable(reason)
                lastError = reason
            case .notDetermined:
                status = .idle
            }
        }
    }

    public func stopListening() {
        guard isListening else { return }
        finish(deliver: true)
    }

    public func cancel() {
        guard isListening || starting else { return }
        starting = false
        finish(deliver: false)
    }

    private func beginSession() {
        guard !isListening else { return }
        guard let recognizer = SFSpeechRecognizer(locale: AppSettings.voiceLocale(from: defaults)), recognizer.isAvailable else {
            status = .unavailable("Speech recognition is unavailable for this language.")
            return
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            status = .unavailable("No microphone input is available.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let onDevice = recognizer.supportsOnDeviceRecognition && AppSettings.speechPreferOnDevice(from: defaults)
        request.requiresOnDeviceRecognition = onDevice
        usesOnDeviceRecognition = onDevice

        session += 1
        let current = session
        delivered = false
        transcript = ""
        Self.installTap(on: engine, format: format, request: request)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            lastError = error.localizedDescription
            status = .idle
            return
        }
        self.engine = engine
        self.request = request
        task = Self.startTask(recognizer: recognizer, request: request) { [weak self] text, isFinal, errorText in
            self?.handle(session: current, text: text, isFinal: isFinal, error: errorText)
        }
        isListening = true
        status = .listening
        AppLog.assistant.debug("speech session started onDevice=\(onDevice)")
        restartSilenceTimer(session: current)
        let maxSeconds = AppSettings.speechMaxUtterance(from: defaults)
        maxTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(maxSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.session == current else { return }
            self.finish(deliver: true)
        }
    }

    // Built outside the main actor so the closures are not main-actor isolated
    // (they run on the audio / speech threads).
    private nonisolated static func installTap(on engine: AVAudioEngine, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest) {
        engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func startTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              deliver: @escaping @MainActor @Sendable (String?, Bool, String?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorText = error?.localizedDescription
            Task { @MainActor in deliver(text, isFinal, errorText) }
        }
    }

    private func handle(session id: Int, text: String?, isFinal: Bool, error: String?) {
        guard id == session, isListening else { return }
        if let text {
            transcript = text
            if !isFinal { restartSilenceTimer(session: id) }
        }
        if isFinal {
            finish(deliver: true)
        } else if let error {
            // A task error after some text still delivers what was heard.
            lastError = error
            AppLog.assistant.error("speech recognition error: \(error)")
            finish(deliver: !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func restartSilenceTimer(session id: Int) {
        silenceTimer?.cancel()
        let seconds = AppSettings.speechSilenceTimeout(from: defaults)
        silenceTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.session == id else { return }
            self.finish(deliver: true)
        }
    }

    private func finish(deliver: Bool) {
        silenceTimer?.cancel()
        silenceTimer = nil
        maxTimer?.cancel()
        maxTimer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        session += 1   // invalidate late callbacks from the finished task
        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldDeliver = deliver && !delivered && !final.isEmpty
        if shouldDeliver { delivered = true }
        isListening = false
        if case .listening = status { status = .idle }
        if shouldDeliver { onUtterance?(final) }
    }
}

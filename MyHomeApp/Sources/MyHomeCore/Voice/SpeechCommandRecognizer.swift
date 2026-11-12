// Push-to-talk speech capture for the assistant, on OFFLINE models only —
// modelled on the Pop app's SpeechListener: Qwen3-ASR first, SenseVoice as the
// fallback (sherpa-onnx), Silero VAD endpointing with Pop's dictation profile,
// AVAudioApplication permission with a handshake watchdog, a liveness probe
// that restarts on the next engine, and bounded model-load / flush timeouts.
// Apple's SFSpeechRecognizer is not used. One session yields at most one
// utterance, delivered through `onUtterance`, or `onNothingHeard` when it
// ended with no words. Transcripts are logged only at .debug, marked private.
import AVFoundation
import Foundation
import os

@MainActor
public final class SpeechCommandRecognizer: ObservableObject {
    public enum Status: Equatable {
        case idle, requestingPermission, listening, unavailable(String)
        /// A recognizer is being constructed (first use loads the model).
        case loadingModel(String)
        /// Capture stopped; the remaining audio is being transcribed.
        case transcribing
    }

    public enum Authorization: Equatable {
        case authorized, denied(String), notDetermined
    }

    public static let microphoneUsageKey = "NSMicrophoneUsageDescription"
    /// Audio tap buffer size in frames.
    nonisolated static let tapBufferSize: AVAudioFrameCount = 1024
    /// How often the endpointer is evaluated while listening.
    nonisolated static let endpointTickSeconds: TimeInterval = 0.1

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var transcript: String = ""
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var lastError: String?
    /// The engine serving the current (or last) session.
    @Published public private(set) var activeEngine: SpeechEngineKind?
    /// Usage key present AND at least one enabled engine has a usable model.
    @Published public private(set) var isSupported: Bool = false
    /// Per-engine install state, refreshed by `refreshSupport()`.
    @Published public private(set) var installedModels: [SpeechEngineKind: InstalledSpeechModel] = [:]
    @Published public private(set) var installing: Set<SpeechEngineKind> = []

    /// Called once per session with the trimmed, non-empty final transcript.
    public var onUtterance: ((String) -> Void)?
    /// Called once when a session that should have delivered ended with no
    /// recognised words (released too early, silence, no-speech timeout).
    public var onNothingHeard: (() -> Void)?
    /// Phrases to favour (device and room names), passed to Qwen3-ASR as
    /// hotwords; asked at the start of each session so renames are picked up.
    public var contextualStrings: (@MainActor () -> [String])?

    private let defaults: UserDefaults
    private let bundle: Bundle
    private let chain: SpeechEngineChain
    private var engine: AVAudioEngine?
    private var feeder: PCMFeeder?
    private var transcriber: SegmentingTranscriber?
    private var endpointer: UtteranceEndpointer?
    private var segments: [String] = []
    private var hadResult = false
    private var tickTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var handshakeWatchdog: Task<Void, Never>?
    private var flushTimer: Task<Void, Never>?
    private var finalizing = false
    private var delivered = false
    private var generation = 0
    private var starting = false
    /// When the user asked to listen (hold-to-talk key-down / mic click);
    /// the gap to a live tap is speech that was never recorded.
    private var requestedAt: TimeInterval?
    /// Session started by hold-to-talk: it ends on key release, not on a pause.
    private var heldOpen = false

    public init(defaults: UserDefaults = .standard, bundle: Bundle = .main, chain: SpeechEngineChain = SpeechEngineChain()) {
        self.defaults = defaults
        self.bundle = bundle
        self.chain = chain
        refreshSupport()
    }

    public static func usageDescriptionsPresent(in bundle: Bundle) -> Bool {
        bundle.infoDictionary?[microphoneUsageKey] != nil
    }

    /// Re-evaluates model install state and `isSupported`.
    public func refreshSupport() {
        let usePop = AppSettings.speechUsePopModels(from: defaults)
        var found: [SpeechEngineKind: InstalledSpeechModel] = [:]
        for kind in SpeechEngineKind.allCases {
            if let model = SpeechModelStore.locate(kind, usePop: usePop) { found[kind] = model }
        }
        installedModels = found
        isSupported = Self.usageDescriptionsPresent(in: bundle) && !engineOrder().isEmpty
    }

    /// Engines to try this session, best first (enabled AND installed).
    func engineOrder() -> [SpeechEngineKind] {
        chain.order(preferred: AppSettings.speechPreferredEngine(from: defaults)) { kind in
            AppSettings.speechEngineEnabled(kind, from: defaults) && installedModels[kind] != nil
        }
    }

    /// Downloads an engine's model into MyHome's own directory (Pop's
    /// install flow; Pop's directory is never written).
    public func installModel(_ kind: SpeechEngineKind) {
        guard !installing.contains(kind) else { return }
        installing.insert(kind)
        lastError = nil
        Task { @MainActor in
            do {
                try await SpeechModelInstaller.shared.install(kind)
            } catch {
                lastError = "\(kind.label) install failed: \(error)"
                AppLog.assistant.error("speech model install failed engine=\(kind.rawValue, privacy: .public)")
            }
            installing.remove(kind)
            refreshSupport()
        }
    }

    @Published public private(set) var installingMlx = false

    /// True when an MLX model is usable (own folder, or Pop's when allowed).
    public var mlxModelInstalled: Bool {
        MlxQwenStore.locate(usePop: AppSettings.speechUsePopModels(from: defaults)) != nil
    }

    /// Downloads the MLX Qwen3-ASR model into MyHome's own directory.
    public func installMlxModel() {
        guard !installingMlx else { return }
        installingMlx = true
        lastError = nil
        Task { @MainActor in
            do { try await MlxQwenStore.install() } catch {
                lastError = "MLX model install failed: \(error)"
                AppLog.assistant.error("mlx speech model install failed")
            }
            installingMlx = false
            refreshSupport()
        }
    }

    // MARK: Authorization (Pop: AVAudioApplication, macOS 14+)

    public func requestAuthorization() async -> Authorization {
        guard Self.usageDescriptionsPresent(in: bundle) else {
            return .denied("This app bundle lacks the microphone usage description; use the Xcode-built app.")
        }
        switch Self.microphonePermission() {
        case .granted: return .authorized
        case .denied: return .denied("Microphone permission was denied.")
        case .undetermined:
            return await Self.requestMicrophoneAccess() ? .authorized : .denied("Microphone permission was denied.")
        }
    }

    enum MicPermission { case granted, denied, undetermined }

    nonisolated static func microphonePermission() -> MicPermission {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .undetermined
        }
    }

    // Callbacks arrive on arbitrary queues, so these are built off the main actor.
    private nonisolated static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        }
    }

    // MARK: Listening

    /// `heldByUser`: hold-to-talk — the session ends on `stopListening()` (key
    /// release) or the max-duration cap, never on a mid-request pause.
    public func startListening(heldByUser: Bool = false) {
        guard !isListening, !starting, !finalizing else { return }
        heldOpen = heldByUser
        refreshSupport()
        lastError = nil
        guard Self.usageDescriptionsPresent(in: bundle) else {
            status = .unavailable("Voice input needs the Xcode-built app (microphone usage description).")
            return
        }
        // NO-MODEL STATE (Pop): an honest install notice; the mic never opens.
        guard !engineOrder().isEmpty else {
            status = .unavailable("No offline speech model is installed — install Qwen3-ASR in Settings → Assistant.")
            return
        }
        starting = true
        requestedAt = ProcessInfo.processInfo.systemUptime
        generation += 1
        let current = generation
        status = .requestingPermission
        armHandshakeWatchdog(generation: current)
        Task { @MainActor in
            let auth = await requestAuthorization()
            guard current == generation, starting else { return }
            cancelHandshakeWatchdog()
            switch auth {
            case .authorized:
                await beginFlow(generation: current)
            case .denied(let reason):
                starting = false
                status = .unavailable(reason)
                lastError = reason
            case .notDetermined:
                starting = false
                status = .idle
            }
        }
    }

    public func stopListening() {
        guard isListening else { return }
        endUtterance()
    }

    public func cancel() {
        guard isListening || starting || finalizing else { return }
        starting = false
        cancelHandshakeWatchdog()
        finish(deliver: false)
    }

    /// Pop's 10 s handshake watchdog: a permission prompt that never answers
    /// cannot leave the mic button stuck.
    private func armHandshakeWatchdog(generation current: Int) {
        handshakeWatchdog?.cancel()
        let seconds = AppSettings.speechHandshakeTimeout(from: defaults)
        handshakeWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.starting, self.generation == current else { return }
            self.starting = false
            self.generation += 1
            self.status = .unavailable("Voice input could not start — no response from the permission system.")
        }
    }

    private func cancelHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
    }

    /// Tries each engine of the chain until one loads and its microphone tap
    /// starts.
    private func beginFlow(generation current: Int, after previous: SpeechEngineKind? = nil) async {
        var order = engineOrder()
        if let previous, let index = order.firstIndex(of: previous) { order = Array(order[(index + 1)...]) }
        let hotwords = AppSettings.speechHotwordBias(from: defaults) ? (contextualStrings?() ?? []) : []
        let profile = AppSettings.speechVADProfile(from: defaults)
        let locale = AppSettings.voiceLocale(from: defaults).identifier
        let pinLanguage = defaults.object(forKey: AppSettings.speechQwenPinLanguageKey) as? Bool
            ?? AppSettings.defaultSpeechQwenPinLanguage
        let loadTimeout = AppSettings.speechModelLoadTimeout(from: defaults)
        let backend = AppSettings.speechQwenBackend(from: defaults)
        let mlxDirectory = backend == AppSettings.speechBackendMlx
            ? MlxQwenStore.locate(usePop: AppSettings.speechUsePopModels(from: defaults)) : nil
        for kind in order {
            guard current == generation, let model = installedModels[kind] else { return }
            status = .loadingModel(kind.label)
            let request = SherpaTranscriberFactory.Request(model: model, profile: profile, hotwords: hotwords,
                                                           localeIdentifier: locale,
                                                           pinQwenLanguage: pinLanguage,
                                                           qwenBackend: backend, mlxDirectory: mlxDirectory)
            let callbacks = Self.makeCallbacks(owner: self, generation: current, kind: kind)
            let built = await Deadline.run(seconds: loadTimeout) {
                await Self.buildOffMain(request, callbacks: callbacks)
            }
            guard current == generation else { return }
            guard let transcriber = built ?? nil else {
                AppLog.assistant.error("speech engine unavailable engine=\(kind.rawValue, privacy: .public) timedOut=\(built == nil)")
                chain.noteDead(kind)
                continue
            }
            // A microphone failure is reported by startCapture; it is not an
            // engine fault, so the chain is not walked further.
            _ = startCapture(transcriber: transcriber, kind: kind, generation: current)
            return
        }
        starting = false
        if isListening { finish(deliver: true) }
        status = .unavailable("No offline speech model could start — check Settings → Assistant.")
    }

    private nonisolated static func buildOffMain(_ request: SherpaTranscriberFactory.Request,
                                                 callbacks: (SegmentingTranscriber.SegmentHandler, SegmentingTranscriber.ActivityHandler))
        async -> SegmentingTranscriber? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SherpaTranscriberFactory.make(request, onSegment: callbacks.0,
                                                                             onActivity: callbacks.1))
            }
        }
    }

    // Built outside the main actor so the closures are not main-actor isolated
    // (they run on the decode queue).
    private nonisolated static func makeCallbacks(owner: SpeechCommandRecognizer, generation: Int, kind: SpeechEngineKind)
        -> (SegmentingTranscriber.SegmentHandler, SegmentingTranscriber.ActivityHandler) {
        let onSegment: SegmentingTranscriber.SegmentHandler = { [weak owner] text in
            Task { @MainActor [weak owner] in owner?.ingestSegment(text, generation: generation, kind: kind) }
        }
        let onActivity: SegmentingTranscriber.ActivityHandler = { [weak owner] active in
            let now = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak owner] in owner?.ingestActivity(active, at: now, generation: generation) }
        }
        return (onSegment, onActivity)
    }

    private nonisolated static func installTap(on engine: AVAudioEngine, format: AVAudioFormat, feeder: PCMFeeder) {
        engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { buffer, _ in
            feeder.feed(buffer)
        }
    }

    /// Pop's tap-format fallback: output format, else the hardware format.
    private func startCapture(transcriber: SegmentingTranscriber, kind: SpeechEngineKind, generation current: Int) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            let hardware = input.inputFormat(forBus: 0)
            if hardware.sampleRate > 0, hardware.channelCount > 0 { format = hardware }
        }
        guard format.sampleRate > 0, format.channelCount > 0,
              let feeder = PCMFeeder(tapFormat: format, sink: transcriber) else {
            failCapture("No microphone input is available.")
            return false
        }
        feeder.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == current, self.isListening else { return }
                self.lastError = "Voice input stopped: \(message)"
                self.endUtterance()
            }
        }
        Self.installTap(on: engine, format: format, feeder: feeder)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            let permission = (error as NSError).domain == NSOSStatusErrorDomain
            failCapture(permission ? "Microphone access is needed for voice input."
                                   : "Could not start the microphone: \(error.localizedDescription)")
            return false
        }
        self.engine = engine
        self.feeder = feeder
        self.transcriber = transcriber
        activeEngine = kind
        hadResult = false
        starting = false
        if !isListening {
            // Fresh session (a liveness restart keeps the transcript so far).
            segments = []
            transcript = ""
            delivered = false
            endpointer = UtteranceEndpointer(policy: AppSettings.speechEndpointPolicy(from: defaults),
                                             startedAt: ProcessInfo.processInfo.systemUptime,
                                             heldOpen: heldOpen)
            startTicking(generation: current)
        }
        isListening = true
        status = .listening
        armLiveness(kind: kind, generation: current)
        let startupMs = requestedAt.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? -1
        requestedAt = nil
        AppLog.assistant.info("speech session started engine=\(kind.rawValue, privacy: .public) startupMs=\(startupMs)")
        return true
    }

    private func failCapture(_ message: String) {
        starting = false
        lastError = message
        if isListening { finish(deliver: true) }
        status = .unavailable(message)
    }

    private func ingestSegment(_ text: String, generation id: Int, kind: SpeechEngineKind) {
        guard id == generation, isListening else { return }
        hadResult = true
        chain.noteGood(kind)
        segments.append(text)
        transcript = SegmentTextJoin.join(segments)
        endpointer?.segmentDecoded(text: text, at: ProcessInfo.processInfo.systemUptime)
    }

    private func ingestActivity(_ active: Bool, at time: TimeInterval, generation id: Int) {
        guard id == generation, isListening else { return }
        endpointer?.speechActivity(active, at: time)
    }

    private func startTicking(generation current: Int) {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.endpointTickSeconds * 1_000_000_000))
                guard let self, self.generation == current, self.isListening, !self.finalizing,
                      let endpointer = self.endpointer else { return }
                switch endpointer.evaluate(at: ProcessInfo.processInfo.systemUptime) {
                case .keepListening: continue
                case .endpoint, .maxDuration: self.endUtterance(); return
                case .noSpeech:
                    self.lastError = "No speech was heard."
                    self.finish(deliver: false, reportEmpty: true)
                    return
                }
            }
        }
    }

    /// Pop's dead-engine restart: no result and no processed window while
    /// audible audio flowed → this engine is dead for the process; tear its
    /// pipeline down silently and continue the SAME session on the next one.
    private func armLiveness(kind: SpeechEngineKind, generation current: Int) {
        livenessTask?.cancel()
        let interval = AppSettings.speechLivenessInterval(from: defaults)
        livenessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled, self.generation == current, self.isListening,
                      !self.finalizing, let feeder = self.feeder else { return }
                let processed = self.transcriber?.processedWindowCount() ?? 0
                guard SpeechLiveness.isDead(hadResult: self.hadResult, processedWindows: processed,
                                            audibleSeconds: feeder.audibleSeconds,
                                            threshold: AppSettings.speechDeadVerdictNonSilentSeconds) else { continue }
                AppLog.assistant.error("speech engine dead engine=\(kind.rawValue, privacy: .public)")
                self.chain.noteDead(kind)
                self.teardownCapture()
                self.transcriber?.finish()
                self.transcriber = nil
                await self.beginFlow(generation: current, after: kind)
                return
            }
        }
    }

    private func teardownCapture() {
        feeder?.stop()
        feeder = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Stops capturing and lets the transcriber decode what is still buffered
    /// (bounded by the flush timeout), then delivers.
    private func endUtterance() {
        guard isListening, !finalizing else { return }
        finalizing = true
        tickTask?.cancel()
        tickTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        teardownCapture()
        status = .transcribing
        let current = generation
        guard let transcriber else { finish(deliver: true); return }
        transcriber.finish { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.finish(deliver: true)
            }
        }
        let seconds = AppSettings.speechFlushTimeout(from: defaults)
        flushTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == current else { return }
            AppLog.assistant.error("speech flush timed out")
            self.finish(deliver: true)
        }
    }

    private func finish(deliver: Bool, reportEmpty: Bool = false) {
        tickTask?.cancel()
        tickTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        flushTimer?.cancel()
        flushTimer = nil
        teardownCapture()
        transcriber?.finish()
        transcriber = nil
        endpointer = nil
        finalizing = false
        generation += 1   // invalidate late callbacks from this session
        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldDeliver = deliver && !delivered && !final.isEmpty
        // A session that failed (mic/conversion error) reports that error, not silence.
        let nothingHeard = (deliver || reportEmpty) && !delivered && final.isEmpty && (reportEmpty || lastError == nil)
        if shouldDeliver || nothingHeard { delivered = true }
        AppLog.assistant.info("speech session ended engine=\(self.activeEngine?.rawValue ?? "none", privacy: .public) segments=\(self.segments.count) chars=\(final.count) delivered=\(shouldDeliver)")
        if shouldDeliver {
            AppLog.assistant.debug("speech transcript: \(final, privacy: .private)")
        }
        isListening = false
        switch status {
        case .listening, .transcribing, .loadingModel, .requestingPermission: status = .idle
        default: break
        }
        if shouldDeliver { onUtterance?(final) }
        if nothingHeard { onNothingHeard?() }
    }
}

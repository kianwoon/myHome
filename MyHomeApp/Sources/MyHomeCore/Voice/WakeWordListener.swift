// Always-on wake word ("Hey Home"), the hands-free twin of hold-to-talk.
// Owns its OWN microphone engine, separate from SpeechCommandRecognizer's
// per-utterance capture, and never touches the recogniser's `isListening`
// (the output gate mutes the speakers on that). The mic is released while
// any pause reason holds — the recogniser listening, a reply being spoken,
// the hotkey held, sleep — so the two captures never overlap and the app
// cannot wake itself. Capture and spotter are injected so the state machine
// is unit tested offline.
import AVFoundation
import Foundation

/// Mic → 16 kHz mono samples. `onSamples` runs on the audio thread.
public protocol WakeAudioCapturing: AnyObject {
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
    /// Main thread: capture died on its own (e.g. a failed device-change restart).
    var onError: ((String) -> Void)? { get set }
}

public enum WakeMicAccess: Sendable { case granted, denied(String) }

@MainActor
public final class WakeWordListener: ObservableObject {
    public enum State: Equatable {
        case off
        case needsModel
        case installing
        case loading
        case armed
        case paused
        case unavailable(String)
    }

    public enum PauseReason: Hashable, CaseIterable {
        case recognizer, speaking, hotkey, sleep, assistant
    }

    @Published public private(set) var state: State = .off
    @Published public private(set) var enabled: Bool

    /// Main thread, once per accepted detection. The listener has already
    /// paused itself (`.recognizer`); the app clears that when the utterance ends.
    public var onWake: (() -> Void)?

    private let defaults: UserDefaults
    private let capture: WakeAudioCapturing
    private let modelInstalled: () -> Bool
    private let makeSpotter: @Sendable () throws -> WakeWordSpotting
    private let installModel: @Sendable () async throws -> Void
    private let authorizeMic: @Sendable () async -> WakeMicAccess
    private let validatePhrase: (String) -> String?
    private var micGranted = false
    private let queue = DispatchQueue(label: "myhome.wake.spotter", qos: .userInitiated)
    private let now: () -> TimeInterval

    private var reasons = Set<PauseReason>()
    private var spotter: WakeWordSpotting?
    private var capturing = false
    /// Bumped on every arm/disarm, so stale detections and loads are dropped.
    private var generation = 0
    private var ignoreUntil: TimeInterval = 0
    private var resumeTask: Task<Void, Never>?
    private var diagnostics: WakeWordDiagnostics?
    private var watchdogs: [PauseReason: Task<Void, Never>] = [:]

    public init(defaults: UserDefaults = .standard,
                capture: WakeAudioCapturing,
                modelInstalled: @escaping () -> Bool = { WakeWordModelStore.isInstalled() },
                makeSpotter: (@Sendable () throws -> WakeWordSpotting)? = nil,
                installModel: @escaping @Sendable () async throws -> Void = { try await WakeWordModelInstaller.shared.install() },
                authorizeMic: @escaping @Sendable () async -> WakeMicAccess = { await WakeWordListener.systemMicAccess() },
                validatePhrase: @escaping (String) -> String? = { WakeWordPhraseEncoder.validate($0) },
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.capture = capture
        self.modelInstalled = modelInstalled
        self.installModel = installModel
        self.authorizeMic = authorizeMic
        self.validatePhrase = validatePhrase
        self.now = now
        self.enabled = AppSettings.wakeWordEnabled(from: defaults)
        self.makeSpotter = makeSpotter ?? {
            try SherpaWakeWordSpotter(config: .init(phrase: AppSettings.wakeWordPhrase(from: defaults),
                                                    boost: AppSettings.wakeWordBoost(from: defaults),
                                                    threshold: AppSettings.wakeWordThreshold(from: defaults)))
        }
        capture.onError = { [weak self] message in
            guard let self, self.capturing else { return }
            self.capturing = false
            self.generation += 1
            self.state = .unavailable("Wake word stopped: \(message)")
        }
    }

    /// Same gate as the recogniser: usage description present (a bare
    /// `swift run` binary would be killed by TCC), then ask once.
    public nonisolated static func systemMicAccess() async -> WakeMicAccess {
        guard Bundle.main.object(forInfoDictionaryKey: SpeechCommandRecognizer.microphoneUsageKey) != nil else {
            return .denied("Voice input needs the Xcode-built app (microphone usage description).")
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            return ok ? .granted : .denied(micDeniedText)
        default: return .denied(micDeniedText)
        }
    }

    nonisolated static let micDeniedText = "Microphone access is off for MyHome (System Settings → Privacy & Security → Microphone)."


    public var phrase: String { AppSettings.wakeWordPhrase(from: defaults) }
    public func isPaused(_ reason: PauseReason) -> Bool { reasons.contains(reason) }

    /// Call once at launch: arms when the stored setting is on.
    public func start() { reconcile() }

    public func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: AppSettings.wakeWordEnabledKey)
        enabled = on
        if !on { spotter = nil }
        reconcile()
    }

    /// Validates against the installed model, persists and rebuilds. Returns
    /// the reason when the phrase cannot be used (nothing changes then).
    @discardableResult
    public func setPhrase(_ phrase: String) -> String? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return WakeWordPhraseError.empty.description }
        if let problem = validatePhrase(trimmed) { return problem }
        defaults.set(trimmed, forKey: AppSettings.wakeWordPhraseKey)
        objectWillChange.send()
        AppLog.assistant.info("wake phrase changed to \(trimmed, privacy: .public)")
        reload()
        return nil
    }

    /// Settings changed (phrase, threshold): rebuild the spotter.
    public func reload() {
        spotter = nil
        disarm()
        reconcile()
    }

    public func setPaused(_ reason: PauseReason, _ paused: Bool) {
        if paused {
            guard reasons.insert(reason).inserted else { return }
            AppLog.assistant.info("wake pause +\(String(describing: reason), privacy: .public) now=\(self.reasonList, privacy: .public)")
            resumeTask?.cancel()
            resumeTask = nil
            armWatchdog(reason)
            reconcile()
        } else {
            guard reasons.remove(reason) != nil else { return }
            AppLog.assistant.info("wake pause -\(String(describing: reason), privacy: .public) now=\(self.reasonList, privacy: .public)")
            watchdogs[reason]?.cancel()
            watchdogs[reason] = nil
            guard reasons.isEmpty else { return }
            // Let the room's echo of the reply die down before re-arming.
            let delay = AppSettings.wakeWordResumeDelay(from: defaults)
            resumeTask?.cancel()
            guard delay > 0 else { reconcile(); return }
            resumeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.resumeTask = nil
                self.reconcile()
            }
        }
    }

    /// Settings "Retry": reinstall only when the model is actually missing.
    public func retry() {
        if modelInstalled() {
            micGranted = false
            state = .off
            reload()
        } else {
            state = .needsModel
            installModelNow()
        }
    }

    private var reasonList: String { reasons.map { String(describing: $0) }.sorted().joined(separator: ",") }

    /// A transient reason whose "end" signal is lost (a TTS callback that never
    /// fires, a recogniser stuck finalising) must not silence the wake word for
    /// good. Hotkey and sleep have reliable ends and no deadline.
    private func armWatchdog(_ reason: PauseReason) {
        guard reason != .hotkey, reason != .sleep else { return }
        watchdogs[reason]?.cancel()
        let limit = AppSettings.wakeWordMaxPause(from: defaults)
        watchdogs[reason] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.reasons.contains(reason) else { return }
            AppLog.assistant.error("wake pause \(String(describing: reason), privacy: .public) still held after \(limit)s; releasing it")
            self.watchdogs[reason] = nil
            self.setPaused(reason, false)
        }
    }

    public func installModelNow() {
        guard state == .needsModel || isUnavailable else { return }
        state = .installing
        Task { @MainActor in
            do {
                try await installModel()
                state = .off
            } catch {
                state = .unavailable("Wake-word model install failed: \(error)")
                return
            }
            reconcile()
        }
    }

    // MARK: State machine

    private var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    private func reconcile() {
        guard enabled else { disarm(); state = .off; return }
        if state == .installing || state == .loading { return }
        guard modelInstalled() else { disarm(); state = .needsModel; return }
        guard reasons.isEmpty, resumeTask == nil else {
            disarm()
            if !isUnavailable { state = .paused }
            return
        }
        if capturing { return }
        if !micGranted {
            state = .loading
            generation += 1
            let current = generation
            let authorize = authorizeMic
            Task { @MainActor [weak self] in
                let access = await authorize()
                guard let self, current == self.generation else { return }
                switch access {
                case .granted:
                    self.micGranted = true
                    self.state = .off
                    self.reconcile()
                case .denied(let reason):
                    self.state = .unavailable(reason)
                }
            }
            return
        }
        if let spotter { arm(spotter); return }
        state = .loading
        generation += 1
        let current = generation
        let make = makeSpotter
        queue.async {
            let result = Result { try make() }
            Task { @MainActor [weak self] in
                guard let self, current == self.generation else { return }
                self.state = .off
                switch result {
                case .success(let built):
                    self.spotter = built
                    self.reconcile()
                case .failure(let error):
                    let text = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                    self.state = .unavailable(text)
                    AppLog.assistant.error("wake spotter build failed: \(text, privacy: .public)")
                }
            }
        }
    }

    private func arm(_ spotter: WakeWordSpotting) {
        generation += 1
        let current = generation
        let queue = self.queue
        queue.async { spotter.reset() }
        let diagnostics = AppSettings.wakeWordDiagnostics(from: defaults) ? WakeWordDiagnostics() : nil
        self.diagnostics = diagnostics
        do {
            try capture.start { [weak self] samples in
                queue.async {
                    let hit = spotter.accept(samples)
                    diagnostics?.observe(samples, hit: hit)
                    guard hit else { return }
                    Task { @MainActor [weak self] in self?.detected(generation: current) }
                }
            }
        } catch {
            state = .unavailable("Wake word could not open the microphone: \(error.localizedDescription)")
            return
        }
        capturing = true
        ignoreUntil = now() + AppSettings.wakeWordCooldown(from: defaults)
        state = .armed
        AppLog.assistant.info("wake word armed phrase=\(self.phrase, privacy: .public) threshold=\(AppSettings.wakeWordThreshold(from: self.defaults)) boost=\(AppSettings.wakeWordBoost(from: self.defaults)) diagnostics=\(diagnostics != nil)")
    }

    private func disarm() {
        generation += 1
        // An in-flight load / permission ask is now stale; don't wait on it.
        if state == .loading { state = .off }
        guard capturing else { return }
        capture.stop()
        if let diagnostics { queue.async { diagnostics.flush() } }
        diagnostics = nil
        capturing = false
    }

    func detected(generation current: Int) {
        guard current == generation, capturing, state == .armed, now() >= ignoreUntil else { return }
        AppLog.assistant.info("wake word detected")
        reasons.insert(.recognizer)   // release the mic BEFORE the recogniser opens it
        reconcile()
        onWake?()
    }
}

// MARK: - Microphone

/// AVAudioEngine tap → PCMFeeder (16 kHz mono). Re-starts itself when the
/// input device changes (AirPods connect, USB mic unplugged).
public final class MicrophoneWakeCapture: WakeAudioCapturing {
    private var engine: AVAudioEngine?
    private var feeder: PCMFeeder?
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var configObserver: NSObjectProtocol?
    public var onError: ((String) -> Void)?

    public init() {}

    private final class Sink: PCMSampleSink {
        let forward: @Sendable ([Float]) -> Void
        init(_ forward: @escaping @Sendable ([Float]) -> Void) { self.forward = forward }
        func append(samples: [Float]) { forward(samples) }
    }

    public func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        stop()
        self.onSamples = onSamples
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 { format = input.inputFormat(forBus: 0) }
        guard format.sampleRate > 0, format.channelCount > 0,
              let feeder = PCMFeeder(tapFormat: format, sink: Sink(onSamples)) else {
            throw NSError(domain: "MyHome.WakeWord", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no microphone input is available"])
        }
        input.installTap(onBus: 0, bufferSize: SpeechCommandRecognizer.tapBufferSize, format: format) { buffer, _ in
            feeder.feed(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        self.engine = engine
        self.feeder = feeder
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, let restart = self.onSamples else { return }
            AppLog.assistant.info("wake capture: input device changed, restarting")
            do {
                try self.start(onSamples: restart)
            } catch {
                self.stop()
                self.onError?("the new microphone could not be opened (\(error.localizedDescription))")
            }
        }
    }

    public func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        feeder?.stop()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        feeder = nil
    }
}

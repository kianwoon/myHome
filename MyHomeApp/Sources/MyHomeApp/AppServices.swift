// Process-wide services. The SwiftUI scenes, the App Intents (Siri /
// Shortcuts run them inside this process) and the command bar all share THIS
// DeviceStore and DeviceController — there is never a second store, so every
// path sees the same optimistic paints, intents and verification state.
import AppKit
import Combine
import Foundation
import MyHomeCore

@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: DeviceStore
    let controller: DeviceController
    let assistant: AssistantCoordinator
    /// Household notes (Application Support/MyHome) the housekeeper reads and edits.
    let notes: HouseholdNotes
    /// The housekeeper agent; attached to the assistant only while enabled.
    let housekeeper: HousekeeperAgent
    let speech: SpeechCommandRecognizer
    let responder: SpeechResponder
    let secrets: SecretStore = KeychainSecretStore()
    let hotkey: HotkeyController
    let hud: HotkeyHUD
    /// Hands-free twin of the hotkey ("Hey Home"); opt-in, off by default.
    let wake: WakeWordListener
    /// Mutes / ducks the speakers while the mic is open (both listening paths).
    let outputGate: ListeningOutputGate
    private var outputHeld = false
    private var outputCancellables = Set<AnyCancellable>()
    private var wakeCancellables = Set<AnyCancellable>()
    /// The current recogniser session is hands-free (the wake word, or a
    /// follow-up answer): strip a leading wake phrase, end silently when empty.
    private var handsFreeSession = false
    /// A spoken question is playing; the mic opens for the answer when it ends.
    private var followUpQuestion: String?
    /// Follow-ups opened since the user last pressed the hotkey / woke it.
    private var followUpTurns = 0
    private var followUpTask: Task<Void, Never>?

    private init() {
        // Before anything reads the provider: a pre-split "jev" provider
        // becomes jevEnabled=true + provider none (idempotent).
        AppSettings.migrateLegacyJevProvider()
        let store = DeviceStore()
        self.store = store
        controller = DeviceController(store: store)
        assistant = AssistantCoordinator(controller: controller,
                                         planner: PlannerFactory.makePlanner(controller: controller, secrets: secrets))
        assistant.jevDecider = PlannerFactory.makeJevDecider(secrets: secrets)
        notes = HouseholdNotes()
        let tools = HousekeeperTools(controller: controller, notes: notes, policy: .fromDefaults(),
                                     outputBudget: AppSettings.housekeeperToolOutputBudget())
        housekeeper = HousekeeperAgent(controller: controller, tools: tools, transport: nil, limits: .fromDefaults(),
                                       persona: AppSettings.plannerInstructions(fallback: PlannerPersona.agent),
                                       snapshotBudget: AppSettings.cloudCatalogueBudget(), snapshotMaxDevices: AppSettings.cloudMaxDevices())
        // Diagnostics: the last reply (and the housekeeper's trace) in last-reply.json.
        assistant.replySink = { reply, utterance, origin, trace in
            LastReplyStore.write(LastReplyRecord(timestamp: Date(), utterance: utterance, origin: origin.rawValue,
                                                 kind: String(describing: reply.kind), source: reply.source, text: reply.text, trace: trace))
        }
        speech = SpeechCommandRecognizer()
        responder = SpeechResponder()
        speech.contextualStrings = { [store] in
            var seen = Set<String>()
            return store.devices.flatMap { [$0.name, $0.room] }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        hotkey = HotkeyController(registrar: CarbonHotkeyRegistrar())
        wake = WakeWordListener(capture: MicrophoneWakeCapture())
        hud = HotkeyHUD(speech: speech, assistant: assistant)
        outputGate = ListeningOutputGate(controller: CoreAudioOutputController())

        // ONE utterance path for the command bar mic AND the global hotkey, so
        // voice works with the main window closed. The command bar only renders.
        speech.onUtterance = { [weak self] utterance in
            guard let self else { return }
            var text = utterance
            if self.handsFreeSession {
                self.handsFreeSession = false
                text = WakePhraseStripper.command(from: utterance, spellings: self.wakeSpellings)
                // Only the wake phrase again (or a false wake): nothing to run, say nothing.
                guard !text.isEmpty else {
                    AppLog.assistant.info("wake session: wake phrase only, ignored")
                    self.hud.abandon()
                    return
                }
            }
            // "Ignore" / "dismiss" / "算了": the user closing the session (wake or hotkey).
            if VoiceDismiss.isDismissal(text) {
                AppLog.assistant.info("voice session dismissed by the user")
                self.assistant.withdrawOpenQuestion()
                self.hud.abandon()
                return
            }
            self.hud.utteranceReceived()
            Task { @MainActor in await self.runVoice(text) }
        }
        speech.onNothingHeard = { [weak self] in
            guard let self else { return }
            // A false wake, or no answer to a spoken question: end silently.
            if self.handsFreeSession {
                self.handsFreeSession = false
                self.hud.abandon()
                return
            }
            self.hud.show(self.assistant.noteNothingHeard())
        }
        hud.onConfirm = { [weak self] in Task { @MainActor in await self?.confirmPending() } }
        hud.onDeny = { [weak self] in self?.denyPending() }
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        wake.onWake = { [weak self] in self?.wakeDetected() }
        bindOutputGate()
        bindWakeWord()
        bindFollowUp()
        reloadHousekeeper()
    }

    // MARK: Output muting while listening

    /// Both the command-bar mic and the hotkey drive the SAME recogniser, so
    /// the gate follows its state: held while the model loads or the mic is
    /// open, released on any other state (idle, cancel, error, transcribing).
    private func bindOutputGate() {
        Publishers.CombineLatest(speech.$status, speech.$isListening)
            .sink { [weak self] status, listening in
                var active = listening
                if case .loadingModel = status { active = true }
                self?.setOutputHeld(active)
            }
            .store(in: &outputCancellables)
        outputGate.$lastEngagement
            .sink { [weak self] engagement in
                if case .unsupported(let message) = engagement { self?.hud.outputNotice = message } else { self?.hud.outputNotice = nil }
            }
            .store(in: &outputCancellables)
    }

    private func setOutputHeld(_ held: Bool) {
        guard held != outputHeld else { return }
        outputHeld = held
        if held { outputGate.begin() } else { outputGate.end() }
    }

    /// Always put the speakers back (quit, sleep).
    func restoreAudioOutput() {
        outputHeld = false
        outputGate.restoreNow()
    }

    /// Launch: undo a mute left behind by a crash / force-quit.
    func recoverAudioOutput() {
        outputGate.recoverPending()
    }

    /// Registers the stored global shortcut (none by default). Called once the
    /// app has finished launching.
    func startHotkey() {
        hotkey.start()
        wake.start()
        // A key-up can be lost across sleep; treat it as a release.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wake.setPaused(.sleep, true)
                self?.disarmFollowUp()
                self?.hotkey.cancelHeld()
                self?.speech.cancel()
                self?.restoreAudioOutput()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake.setPaused(.sleep, false) }
        }
    }

    // MARK: Voice (shared by the command bar and the hotkey)

    private func runVoice(_ utterance: String) async {
        wake.setPaused(.assistant, true)
        defer { wake.setPaused(.assistant, false) }
        let reply = await assistant.handle(utterance, origin: .voice)
        outputGate.settle()   // the spoken reply must be audible
        let listen = VoiceFollowUp.shouldListen(after: reply.kind, enabled: AppSettings.voiceFollowUpEnabled(),
                                                turnsSoFar: followUpTurns, maxTurns: AppSettings.voiceFollowUpMaxTurns())
        if VoiceFollowUp.asksForAnswer(reply.kind), !listen {
            AppLog.assistant.info("follow-up not opened (off or \(self.followUpTurns, privacy: .public) already)")
        }
        followUpQuestion = listen ? reply.text : nil
        if !listen { followUpTurns = 0 }
        responder.speak(reply.text)
        hud.show(reply)
        // Spoken replies off (or nothing to say): no speech end will come.
        if listen, !responder.isSpeaking { scheduleFollowUp() }
    }

    // MARK: Follow-up answer ("Which fan?" → "the living room one")

    private func bindFollowUp() {
        responder.$isSpeaking
            .sink { [weak self] speaking in
                guard let self, !speaking, self.followUpQuestion != nil else { return }
                self.scheduleFollowUp()
            }
            .store(in: &wakeCancellables)
    }

    /// After the echo delay, open the mic hands-free for the answer.
    private func scheduleFollowUp() {
        followUpTask?.cancel()
        let delay = AppSettings.voiceFollowUpDelay()
        followUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, let question = self.followUpQuestion else { return }
            self.followUpQuestion = nil
            self.followUpTask = nil
            self.followUpTurns += 1
            AppLog.assistant.info("follow-up listening (turn \(self.followUpTurns, privacy: .public))")
            self.startHandsFree(question: question, source: "follow-up")
        }
    }

    /// Call before anything that stops the reply (`responder.stop()` drops
    /// `isSpeaking`, which would otherwise open the mic).
    private func disarmFollowUp() {
        followUpQuestion = nil
        followUpTask?.cancel()
        followUpTask = nil
    }

    func confirmPending() async {
        disarmFollowUp()   // answered on the HUD instead
        if let reply = await assistant.confirmPending() {
            outputGate.settle()
            responder.speak(reply.text)
            hud.show(reply)
        }
    }

    func denyPending() {
        disarmFollowUp()
        let reply = assistant.cancelPending()
        hud.show(reply)
    }

    // MARK: Hold-to-talk

    /// Press only starts listening; policy checks and confirmations are unchanged.
    private func hotkeyPressed() {
        disarmFollowUp()
        followUpTurns = 0
        handsFreeSession = false
        responder.stop()
        hud.begin()
        speech.startListening(heldByUser: true)
    }

    private func hotkeyReleased() {
        hud.released()
        if speech.isListening {
            speech.stopListening()
        } else if speechIsStarting {
            // Released before the model / permission was ready: never leave the
            // recogniser to start listening with nobody holding the key.
            speech.cancel()
            hud.abandon()
        }
    }

    // MARK: Wake word

    /// The wake listener's mic is released whenever the recogniser, a spoken
    /// reply or the hotkey could be using the microphone or the speakers.
    private func bindWakeWord() {
        Publishers.CombineLatest(speech.$status, speech.$isListening)
            .sink { [weak self] status, listening in
                self?.wake.setPaused(.recognizer, listening || Self.speechBusy(status))
            }
            .store(in: &wakeCancellables)
        responder.$isSpeaking
            .sink { [weak self] speaking in self?.wake.setPaused(.speaking, speaking) }
            .store(in: &wakeCancellables)
        hotkey.$isHeld
            .sink { [weak self] held in self?.wake.setPaused(.hotkey, held) }
            .store(in: &wakeCancellables)
    }

    /// The typed phrase itself, plus (for the default "Hey Home") the ASR
    /// spellings measured on a real voice.
    private var wakeSpellings: [String] {
        let phrase = wake.phrase
        var spellings = [phrase]
        if phrase.uppercased() == AppSettings.defaultWakeWordPhrase { spellings += AppSettings.wakePhraseSpellings() }
        return spellings
    }

    private static func speechBusy(_ status: SpeechCommandRecognizer.Status) -> Bool {
        switch status {
        case .requestingPermission, .loadingModel, .listening, .transcribing: return true
        case .idle, .unavailable: return false
        }
    }

    /// Same path as a hotkey press, but the recogniser ends the utterance on
    /// its own endpointer (no key release). The chime tells the user to speak.
    private func wakeDetected() {
        disarmFollowUp()
        followUpTurns = 0
        responder.stop()
        let chime = AppSettings.wakeWordChime()
        if !chime.isEmpty { NSSound(named: NSSound.Name(chime))?.play() }
        startHandsFree(question: nil, source: "wake")
    }

    /// Listening with no key held: the recogniser's endpointer ends the
    /// utterance (wake word, or the answer to a spoken question).
    private func startHandsFree(question: String?, source: String) {
        hud.begin(question: question)
        handsFreeSession = true
        speech.startListening(heldByUser: false, noSpeechTimeout: AppSettings.wakeNoSpeechTimeout(),
                             hangover: AppSettings.wakeHangover())
        // The recogniser refused to start (no model, busy): re-arm now.
        // An unavailable status stays on the HUD (it says why); anything else hides it.
        if !speech.isListening && !Self.speechBusy(speech.status) {
            AppLog.assistant.info("\(source, privacy: .public) listening refused status=\(String(describing: self.speech.status), privacy: .public)")
            if case .unavailable = speech.status {} else { hud.abandon() }
            handsFreeSession = false
            wake.setPaused(.recognizer, false)
        }
    }

    private var speechIsStarting: Bool {
        switch speech.status {
        case .requestingPermission, .loadingModel: return true
        default: return false
        }
    }

    /// Re-reads Settings → Assistant (provider changed). Other planner fields
    /// are read on every request.
    func reloadPlanner() {
        assistant.planner = PlannerFactory.makePlanner(controller: controller, secrets: secrets)
        assistant.jevDecider = PlannerFactory.makeJevDecider(secrets: secrets)
        reloadHousekeeper()
    }

    /// Re-reads Settings → AI Models → Housekeeper agent (and the Cloud LLM
    /// provider it runs on). The agent is detached while disabled.
    func reloadHousekeeper() {
        housekeeper.transport = AgentTransportFactory.make(secrets: secrets, requestTimeout: AppSettings.housekeeperRequestTimeout())
        housekeeper.limits = .fromDefaults()
        housekeeper.tools.policy = .fromDefaults()
        housekeeper.tools.outputBudget = AppSettings.housekeeperToolOutputBudget()
        housekeeper.persona = AppSettings.plannerInstructions(fallback: PlannerPersona.agent)
        housekeeper.snapshotBudget = AppSettings.cloudCatalogueBudget()
        housekeeper.snapshotMaxDevices = AppSettings.cloudMaxDevices()
        assistant.housekeeper = AppSettings.housekeeperEnabled() ? housekeeper : nil
        assistant.housekeeperFastPath = AppSettings.housekeeperFastPath()
    }

    // MARK: Diagnostics (--say / myhome://say / --probe-tools)

    /// Runs `text` exactly like a typed command, once the roster and the
    /// Briturn states are loaded (a cold launch snapshots nothing otherwise).
    @discardableResult
    func sayForDiagnostics(_ text: String, via: String, origin: CommandOrigin) async -> AssistantReply {
        AppLog.assistant.notice("diagnostic say via \(via, privacy: .public): \(text, privacy: .public)")
        await ensureRosterLoaded()
        await store.loadAllBriturnStatuses()
        let unread = controller.summaries().filter { $0.isControllable && $0.isOn == nil }.count
        AppLog.assistant.notice("diagnostic say: roster=\(self.store.devices.count, privacy: .public) controllableWithoutReading=\(unread, privacy: .public)")
        return await assistant.handle(text, origin: origin)
    }

    /// Learns how the configured provider passes tool calls; the outcome is
    /// recorded in UserDefaults and in last-reply.json.
    @discardableResult
    func probeToolsForDiagnostics() async -> AgentToolProbe.Outcome {
        let outcome = await AgentToolProbe.runAndRecord(secrets: secrets)
        LastReplyStore.write(LastReplyRecord(timestamp: Date(), utterance: AppSettings.probeLaunchArgument, origin: "diagnostic",
                                             kind: "probe", source: "probe", text: outcome.summary, trace: nil))
        reloadHousekeeper()
        return outcome
    }

    /// An intent can run before any window loaded the roster (cold launch
    /// from Shortcuts). One bounded refresh — never a poll loop.
    func ensureRosterLoaded() async {
        if store.roster.isEmpty { await store.refresh() }
    }
}

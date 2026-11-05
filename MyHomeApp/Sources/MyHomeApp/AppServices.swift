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
    let speech: SpeechCommandRecognizer
    let responder: SpeechResponder
    let secrets: SecretStore = KeychainSecretStore()
    let hotkey: HotkeyController
    let hud: HotkeyHUD
    /// Mutes / ducks the speakers while the mic is open (both listening paths).
    let outputGate: ListeningOutputGate
    private var outputHeld = false
    private var outputCancellables = Set<AnyCancellable>()

    private init() {
        let store = DeviceStore()
        self.store = store
        controller = DeviceController(store: store)
        assistant = AssistantCoordinator(controller: controller,
                                         planner: PlannerFactory.makePlanner(controller: controller, secrets: secrets))
        assistant.jevDecider = PlannerFactory.makeJevDecider(secrets: secrets)
        speech = SpeechCommandRecognizer()
        responder = SpeechResponder()
        speech.contextualStrings = { [store] in
            var seen = Set<String>()
            return store.devices.flatMap { [$0.name, $0.room] }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        hotkey = HotkeyController(registrar: CarbonHotkeyRegistrar())
        hud = HotkeyHUD(speech: speech, assistant: assistant)
        outputGate = ListeningOutputGate(controller: CoreAudioOutputController())

        // ONE utterance path for the command bar mic AND the global hotkey, so
        // voice works with the main window closed. The command bar only renders.
        speech.onUtterance = { [weak self] utterance in
            self?.hud.utteranceReceived()
            Task { @MainActor in await self?.runVoice(utterance) }
        }
        speech.onNothingHeard = { [weak self] in
            guard let self else { return }
            self.hud.show(self.assistant.noteNothingHeard())
        }
        hud.onConfirm = { [weak self] in Task { @MainActor in await self?.confirmPending() } }
        hud.onDeny = { [weak self] in self?.denyPending() }
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        bindOutputGate()
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
        // A key-up can be lost across sleep; treat it as a release.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotkey.cancelHeld()
                self?.speech.cancel()
                self?.restoreAudioOutput()
            }
        }
    }

    // MARK: Voice (shared by the command bar and the hotkey)

    private func runVoice(_ utterance: String) async {
        let reply = await assistant.handle(utterance, origin: .voice)
        outputGate.settle()   // the spoken reply must be audible
        responder.speak(reply.text)
        hud.show(reply)
    }

    func confirmPending() async {
        if let reply = await assistant.confirmPending() {
            outputGate.settle()
            responder.speak(reply.text)
            hud.show(reply)
        }
    }

    func denyPending() {
        let reply = assistant.cancelPending()
        hud.show(reply)
    }

    // MARK: Hold-to-talk

    /// Press only starts listening; policy checks and confirmations are unchanged.
    private func hotkeyPressed() {
        responder.stop()
        hud.begin()
        speech.startListening()
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
    }

    /// An intent can run before any window loaded the roster (cold launch
    /// from Shortcuts). One bounded refresh — never a poll loop.
    func ensureRosterLoaded() async {
        if store.roster.isEmpty { await store.refresh() }
    }
}

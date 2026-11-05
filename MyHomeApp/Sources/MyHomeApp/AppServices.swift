// Process-wide services. The SwiftUI scenes, the App Intents (Siri /
// Shortcuts run them inside this process) and the command bar all share THIS
// DeviceStore and DeviceController — there is never a second store, so every
// path sees the same optimistic paints, intents and verification state.
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

    private init() {
        let store = DeviceStore()
        self.store = store
        controller = DeviceController(store: store)
        assistant = AssistantCoordinator(controller: controller,
                                         planner: PlannerFactory.makePlanner(controller: controller, secrets: secrets))
        speech = SpeechCommandRecognizer()
        responder = SpeechResponder()
        speech.contextualStrings = { [store] in
            var seen = Set<String>()
            return store.devices.flatMap { [$0.name, $0.room] }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    /// Re-reads Settings → Assistant (provider changed). Other planner fields
    /// are read on every request.
    func reloadPlanner() {
        assistant.planner = PlannerFactory.makePlanner(controller: controller, secrets: secrets)
    }

    /// An intent can run before any window loaded the roster (cold launch
    /// from Shortcuts). One bounded refresh — never a poll loop.
    func ensureRosterLoaded() async {
        if store.roster.isEmpty { await store.refresh() }
    }
}

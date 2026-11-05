// Settings → AI Planner → Jev decider fields: endpoint, model, key, gate,
// timeout and a live "Test connection". Defaults and ranges come from
// JevSettings.swift; the key lives in the Keychain (never UserDefaults).
import MyHomeCore
import SwiftUI

struct JevSettingsFields: View {
    let services: AppServices
    @AppStorage(AppSettings.jevEndpointKey) private var endpoint = ""
    @AppStorage(AppSettings.jevModelKey) private var model = ""
    @AppStorage(AppSettings.jevThresholdKey) private var threshold = AppSettings.defaultJevThreshold
    @AppStorage(AppSettings.jevTimeoutKey) private var timeout = AppSettings.defaultJevTimeout
    @StateObject private var keyEntry: SecretKeyEntryModel

    init(services: AppServices) {
        self.services = services
        _keyEntry = StateObject(wrappedValue: SecretKeyEntryModel(account: AppSettings.jevSecretAccount, secrets: services.secrets,
                                                                  environmentVariable: AppSettings.jevKeyEnvironmentVariable))
    }

    var body: some View {
        TextField("Decisions endpoint", text: $endpoint, prompt: Text(AppSettings.defaultJevEndpoint))
        TextField("Model", text: $model, prompt: Text(AppSettings.jevModelPlaceholder))
        SecretKeyEntryView(model: keyEntry, placeholder: keyPrompt)
        HStack {
            Text("Accept at")
            Slider(value: $threshold, in: AppSettings.jevThresholdRange, step: AppSettings.jevThresholdStep)
            Text("\(Int((threshold * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        Stepper(String(format: "Request timeout %.0fs (per attempt)", timeout), value: $timeout, in: AppSettings.jevTimeoutRange, step: 1)
        SecretKeyTestRow(model: keyEntry) { [services] in await JevCommandDecider(secrets: services.secrets).testConnection() }
            .onAppear { keyEntry.onStoredKeyChange = { [services] in services.reloadPlanner() } }
    }

    private var keyPrompt: String {
        if keyEntry.hasStoredKey { return "Saved in Keychain (paste to replace)" }
        let envSet = !(ProcessInfo.processInfo.environment[AppSettings.jevKeyEnvironmentVariable] ?? "").isEmpty
        return envSet ? "Using \(AppSettings.jevKeyEnvironmentVariable) (paste to override)" : "Paste OpenRouter key"
    }

    // allow-hardcode: UI copy.
    static let privacyNote = "Privacy: when the grammar cannot settle a request, your command and your device names, room names, kinds and capabilities are sent to the Jev decisions endpoint above. Device ids, states and credentials are not. Jev only picks a device and an action; every match is confirmed before anything runs, and a failed or unsure answer asks you instead of guessing. The key is kept in the macOS Keychain (or read from OPENROUTER_API_KEY)."
}

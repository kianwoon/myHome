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
    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        TextField("Decisions endpoint", text: $endpoint, prompt: Text(AppSettings.defaultJevEndpoint))
        TextField("Model", text: $model, prompt: Text(AppSettings.jevModelPlaceholder))
        SecureField("API key", text: $apiKey, prompt: Text(keyPrompt))
        HStack {
            Button("Save key") { saveKey() }.disabled(apiKey.isEmpty)
            Button("Remove key") { removeKey() }.disabled(!keyIsSaved)
            Text(keyStatus).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Text("Accept at")
            Slider(value: $threshold, in: AppSettings.jevThresholdRange, step: AppSettings.jevThresholdStep)
            Text("\(Int((threshold * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        Stepper(String(format: "Request timeout %.0fs (per attempt)", timeout), value: $timeout, in: AppSettings.jevTimeoutRange, step: 1)
        HStack {
            Button(testing ? "Testing…" : "Test connection") { Task { await testConnection() } }
                .disabled(testing)
            Text(testResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var keyIsSaved: Bool {
        ResolvedSecret.resolve(secrets: services.secrets, account: AppSettings.jevSecretAccount).source == .keychain
    }

    private var keyPrompt: String {
        if keyIsSaved { return "Saved in Keychain (type to replace)" }
        let envSet = !(ProcessInfo.processInfo.environment[AppSettings.jevKeyEnvironmentVariable] ?? "").isEmpty
        return envSet ? "Using \(AppSettings.jevKeyEnvironmentVariable) (paste to override)" : "Paste OpenRouter key"
    }

    private func saveKey() {
        keyStatus = saveSecretVerified(apiKey, account: AppSettings.jevSecretAccount, in: services.secrets)
        if keyStatus.hasPrefix("Key saved") { apiKey = "" }
    }

    private func removeKey() {
        do {
            try services.secrets.delete(account: AppSettings.jevSecretAccount)
            keyStatus = "Key removed."
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func testConnection() async {
        if !apiKey.isEmpty {
            saveKey()
            if !keyStatus.hasPrefix("Key saved") { testResult = keyStatus; return }   // refused: do not test the old key
        }
        testing = true
        defer { testing = false }
        testResult = await JevCommandDecider(secrets: services.secrets).testConnection()
    }

    // allow-hardcode: UI copy.
    static let privacyNote = "Privacy: when the grammar cannot settle a request, your command and your device names, room names, kinds and capabilities are sent to the Jev decisions endpoint above. Device ids, states and credentials are not. Jev only picks a device and an action; every match is confirmed before anything runs, and a failed or unsure answer asks you instead of guessing. The key is kept in the macOS Keychain (or read from OPENROUTER_API_KEY)."
}

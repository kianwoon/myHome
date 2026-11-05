// Settings → Assistant: the voice / planner knobs behind AppSettings.
import MyHomeCore
import SwiftUI

struct AssistantSettingsView: View {
    @AppStorage(AppSettings.spokenRepliesKey) private var spokenReplies = AppSettings.defaultSpokenReplies
    @AppStorage(AppSettings.voiceLocaleKey) private var voiceLocale = ""
    @AppStorage(AppSettings.plannerProviderKey) private var provider = AppSettings.defaultPlannerProvider
    @AppStorage(AppSettings.anthropicBaseURLKey) private var anthropicURL = ""
    @AppStorage(AppSettings.openAIBaseURLKey) private var openAIURL = ""
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = ""
    @AppStorage(AppSettings.openAIModelKey) private var openAIModel = ""
    @AppStorage(AppSettings.plannerTimeoutKey) private var plannerTimeout = AppSettings.defaultPlannerTimeout
    @AppStorage(AppSettings.plannerMaxTokensKey) private var maxTokens = AppSettings.defaultPlannerMaxTokens
    @AppStorage(AppSettings.assistantCommandTimeoutKey) private var commandTimeout = AppSettings.defaultAssistantCommandTimeout
    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var testResult = ""
    @State private var testing = false
    @AppStorage(AppSettings.confirmDeviceCountKey) private var confirmCount = AppSettings.defaultConfirmDeviceCount
    @AppStorage(AppSettings.commandVerifyTimeoutKey) private var verifyTimeout = AppSettings.defaultCommandVerifyTimeout

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var body: some View {
        Form {
            Section {
                Toggle("Speak replies", isOn: $spokenReplies)
                TextField("Voice language (e.g. en-GB; empty = system)", text: $voiceLocale)
            } header: {
                Text("Voice")
            } footer: {
                Text(voiceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SpeechEngineSettingsSection(speech: services.speech)

            HotkeySettingsSection(hotkey: services.hotkey)

            Section {
                Picker("Planner for free-form requests", selection: $provider) {
                    Text("None (direct commands only)").tag(AppSettings.PlannerProvider.none)
                    Text("Apple on-device").tag(AppSettings.PlannerProvider.apple)
                    Text("Anthropic API").tag(AppSettings.PlannerProvider.anthropic)
                    Text("OpenAI-compatible").tag(AppSettings.PlannerProvider.openAICompatible)
                }
                if provider.isCloud { cloudFields }
            } header: {
                Text("Natural language")
            } footer: {
                Text(plannerNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper("Ask before changing \(confirmCount) or more devices", value: $confirmCount, in: AppSettings.confirmDeviceCountRange)
                Stepper(String(format: "Wait %.1fs for a device to confirm a change", verifyTimeout),
                        value: $verifyTimeout, in: AppSettings.commandVerifyTimeoutRange, step: 0.5)
            } header: {
                Text("Safety")
            } footer: {
                Text("Model-planned requests always ask first. Changes apply to the next command; the controller re-reads these settings when a command starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onChange(of: provider) { _ in
            testResult = ""
            keyStatus = ""
            services.reloadPlanner()
        }
        .onChange(of: confirmCount) { _ in services.controller.config = .fromDefaults() }
        .onChange(of: verifyTimeout) { _ in services.controller.config = .fromDefaults() }
    }

    private var voiceNote: String {
        if !SpeechCommandRecognizer.usageDescriptionsPresent(in: .main) {
            return "Voice input needs the Xcode-built app bundle (microphone usage description). Typed commands work everywhere."
        }
        return services.speech.isSupported
            ? "Push to talk from the command bar (⇧⌘M). Recognition runs offline on this Mac."
            : "No offline speech model is ready — install one under Speech engine below."
    }

    @ViewBuilder
    private var cloudFields: some View {
        TextField("Base URL", text: baseURL, prompt: Text(defaultBaseURL))
        TextField("Model", text: model, prompt: Text(modelPlaceholder))
        SecureField("API key", text: $apiKey, prompt: Text(keyIsSaved ? "Saved in Keychain (type to replace)" : "Paste key"))
        HStack {
            Button("Save key") { saveKey() }.disabled(apiKey.isEmpty)
            Button("Remove key") { removeKey() }.disabled(!keyIsSaved)
            Text(keyStatus).font(.caption).foregroundStyle(.secondary)
        }
        Stepper(String(format: "Request timeout %.0fs", plannerTimeout), value: $plannerTimeout, in: AppSettings.plannerTimeoutRange, step: 1)
        Stepper("Max reply tokens \(maxTokens)", value: $maxTokens, in: AppSettings.plannerMaxTokensRange, step: 64)
        HStack {
            Button(testing ? "Testing…" : "Test connection") { Task { await testConnection() } }
                .disabled(testing)
            Text(testResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var account: String { AppSettings.plannerSecretAccount(for: provider) }

    private var keyIsSaved: Bool { ((try? services.secrets.read(account: account)) ?? nil)?.isEmpty == false }

    private var defaultBaseURL: String {
        provider == .anthropic ? AppSettings.defaultAnthropicBaseURL : AppSettings.defaultOpenAIBaseURL
    }

    private var modelPlaceholder: String {
        provider == .anthropic ? AppSettings.anthropicModelPlaceholder : AppSettings.openAIModelPlaceholder
    }

    private var baseURL: Binding<String> { provider == .anthropic ? $anthropicURL : $openAIURL }
    private var model: Binding<String> { provider == .anthropic ? $anthropicModel : $openAIModel }

    private func saveKey() {
        do {
            try services.secrets.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
            apiKey = ""
            keyStatus = "Key saved in Keychain."
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try services.secrets.delete(account: account)
            keyStatus = "Key removed."
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func testConnection() async {
        if !apiKey.isEmpty { saveKey() }
        testing = true
        defer { testing = false }
        let planner = CloudPlanner(controller: services.controller, secrets: services.secrets)
        testResult = await planner.testConnection()
    }

    private var plannerNote: String {
        switch provider {
        case .none:
            return "Only direct commands (turn on / set to 50%) are understood; nothing is sent anywhere."
        case .apple:
            if let note = PlannerFactory.platformNote() { return note + " Direct commands work without it." }
            if let reason = services.assistant.planner?.unavailableReason { return "Unavailable: \(reason)." }
            return "Requests the grammar cannot parse are planned by the on-device model; the plan is confirmed before anything runs."
        case .anthropic, .openAICompatible:
            return "Privacy: when the grammar cannot parse a request, your command and your device names, room names, kinds and capabilities are sent to the provider above. Device ids, states and credentials are not. The key is kept in the macOS Keychain. Plans are always confirmed before anything runs."
        }
    }
}

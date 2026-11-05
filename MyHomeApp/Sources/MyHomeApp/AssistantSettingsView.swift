// Settings tabs behind AppSettings: Voice, Speech, Hotkey, AI Planner and
// Assistant (safety). The tabs are assembled in SettingsView.
import MyHomeCore
import SwiftUI

/// Voice tab: spoken replies, voice language and the listening (VAD) knobs.
struct VoiceSettingsView: View {
    @AppStorage(AppSettings.spokenRepliesKey) private var spokenReplies = AppSettings.defaultSpokenReplies
    @AppStorage(AppSettings.voiceLocaleKey) private var voiceLocale = ""

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

            SpeechListeningSettingsSection()
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    private var voiceNote: String {
        if !SpeechCommandRecognizer.usageDescriptionsPresent(in: .main) {
            return "Voice input needs the Xcode-built app bundle (microphone usage description). Typed commands work everywhere."
        }
        return services.speech.isSupported
            ? "Push to talk from the command bar (⇧⌘M). Recognition runs offline on this Mac."
            : "No offline speech model is ready — install one on the Speech tab."
    }
}

/// Speech tab: engine choice and offline model install state.
struct SpeechSettingsView: View {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var body: some View {
        Form {
            SpeechEngineSettingsSection(speech: services.speech)
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}

/// Hotkey tab: hold-to-talk shortcut and the while-listening output mute.
struct HotkeySettingsView: View {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var body: some View {
        Form {
            HotkeySettingsSection(hotkey: services.hotkey)
            OutputMuteSettingsSection(gate: services.outputGate)
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}

/// AI Planner tab: provider picker; provider-specific fields only for the
/// selected provider (cloud fields for Anthropic / OpenAI, Jev fields for Jev).
struct PlannerSettingsView: View {
    @AppStorage(AppSettings.plannerProviderKey) private var provider = AppSettings.defaultPlannerProvider

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var body: some View {
        Form {
            Section {
                Picker("Planner for free-form requests", selection: $provider) {
                    Text("None (direct commands only)").tag(AppSettings.PlannerProvider.none)
                    Text("Apple on-device").tag(AppSettings.PlannerProvider.apple)
                    Text("Anthropic API").tag(AppSettings.PlannerProvider.anthropic)
                    Text("OpenAI-compatible").tag(AppSettings.PlannerProvider.openAICompatible)
                    Text("Jev decider (OpenRouter)").tag(AppSettings.PlannerProvider.jev)
                }
                // .id(provider): a fresh key model and field per provider/account.
                if provider.isCloud { CloudPlannerFields(services: services, provider: provider).id(provider) }
                if provider == .jev { JevSettingsFields(services: services) }
            } header: {
                Text("Natural language")
            } footer: {
                Text(plannerNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onChange(of: provider) { _ in services.reloadPlanner() }
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
        case .jev:
            return JevSettingsFields.privacyNote
        }
    }
}

/// Cloud planner (Anthropic / OpenAI-compatible) fields for one provider.
struct CloudPlannerFields: View {
    @AppStorage(AppSettings.anthropicBaseURLKey) private var anthropicURL = ""
    @AppStorage(AppSettings.openAIBaseURLKey) private var openAIURL = ""
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = ""
    @AppStorage(AppSettings.openAIModelKey) private var openAIModel = ""
    @AppStorage(AppSettings.plannerTimeoutKey) private var plannerTimeout = AppSettings.defaultPlannerTimeout
    @AppStorage(AppSettings.plannerMaxTokensKey) private var maxTokens = AppSettings.defaultPlannerMaxTokens
    @StateObject private var keyEntry: SecretKeyEntryModel

    private let services: AppServices
    private let provider: AppSettings.PlannerProvider

    init(services: AppServices, provider: AppSettings.PlannerProvider) {
        self.services = services
        self.provider = provider
        _keyEntry = StateObject(wrappedValue: SecretKeyEntryModel(account: AppSettings.plannerSecretAccount(for: provider),
                                                                  secrets: services.secrets))
    }

    var body: some View {
        TextField("Base URL", text: baseURL, prompt: Text(defaultBaseURL))
        TextField("Model", text: model, prompt: Text(modelPlaceholder))
        SecretKeyEntryView(model: keyEntry, placeholder: keyEntry.hasStoredKey ? "Saved in Keychain (paste to replace)" : "Paste key")
        Stepper(String(format: "Request timeout %.0fs", plannerTimeout), value: $plannerTimeout, in: AppSettings.plannerTimeoutRange, step: 1)
        Stepper("Max reply tokens \(maxTokens)", value: $maxTokens, in: AppSettings.plannerMaxTokensRange, step: 64)
        SecretKeyTestRow(model: keyEntry) { [services] in
            await CloudPlanner(controller: services.controller, secrets: services.secrets).testConnection()
        }
        .onAppear { keyEntry.onStoredKeyChange = { [services] in services.reloadPlanner() } }
    }

    private var defaultBaseURL: String {
        provider == .anthropic ? AppSettings.defaultAnthropicBaseURL : AppSettings.defaultOpenAIBaseURL
    }

    private var modelPlaceholder: String {
        provider == .anthropic ? AppSettings.anthropicModelPlaceholder : AppSettings.openAIModelPlaceholder
    }

    private var baseURL: Binding<String> { provider == .anthropic ? $anthropicURL : $openAIURL }
    private var model: Binding<String> { provider == .anthropic ? $anthropicModel : $openAIModel }
}

/// Assistant tab: safety settings for executed commands.
struct AssistantSettingsView: View {
    @AppStorage(AppSettings.confirmDeviceCountKey) private var confirmCount = AppSettings.defaultConfirmDeviceCount
    @AppStorage(AppSettings.commandVerifyTimeoutKey) private var verifyTimeout = AppSettings.defaultCommandVerifyTimeout
    @AppStorage(AppSettings.assistantCommandTimeoutKey) private var commandTimeout = AppSettings.defaultAssistantCommandTimeout

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var body: some View {
        Form {
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
        .onChange(of: confirmCount) { _ in services.controller.config = .fromDefaults() }
        .onChange(of: verifyTimeout) { _ in services.controller.config = .fromDefaults() }
    }
}

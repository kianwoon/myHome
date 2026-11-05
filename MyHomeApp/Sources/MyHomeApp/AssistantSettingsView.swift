// Settings → Assistant: the voice / planner knobs behind AppSettings.
import MyHomeCore
import SwiftUI

struct AssistantSettingsView: View {
    @AppStorage(AppSettings.spokenRepliesKey) private var spokenReplies = AppSettings.defaultSpokenReplies
    @AppStorage(AppSettings.speechPreferOnDeviceKey) private var preferOnDevice = AppSettings.defaultSpeechPreferOnDevice
    @AppStorage(AppSettings.voiceLocaleKey) private var voiceLocale = ""
    @AppStorage(AppSettings.plannerEnabledKey) private var plannerEnabled = AppSettings.defaultPlannerEnabled
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
                Toggle("Prefer on-device speech recognition", isOn: $preferOnDevice)
                TextField("Voice language (e.g. en-GB; empty = system)", text: $voiceLocale)
            } header: {
                Text("Voice")
            } footer: {
                Text(voiceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Plan free-form requests with the on-device model", isOn: $plannerEnabled)
            } header: {
                Text("Natural language (Apple Intelligence)")
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
        .onChange(of: confirmCount) { _ in services.controller.config = .fromDefaults() }
        .onChange(of: verifyTimeout) { _ in services.controller.config = .fromDefaults() }
    }

    private var voiceNote: String {
        if !SpeechCommandRecognizer.usageDescriptionsPresent(in: .main) {
            return "Voice input needs the Xcode-built app bundle (microphone and speech usage descriptions). Typed commands work everywhere."
        }
        return services.speech.isSupported
            ? "Push to talk from the command bar (⇧⌘M). Recognition runs on this Mac when the language supports it."
            : "Speech recognition is unavailable for the selected language."
    }

    private var plannerNote: String {
        if let note = PlannerFactory.platformNote() { return note + " Direct commands (turn on / set to 50%) work without it." }
        if let reason = services.assistant.planner?.unavailableReason { return "Unavailable: \(reason)." }
        return "Requests the grammar cannot parse are planned by the on-device model; the plan is shown and confirmed before anything runs."
    }
}

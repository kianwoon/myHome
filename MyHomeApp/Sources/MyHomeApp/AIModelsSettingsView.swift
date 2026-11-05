// Settings → AI Models: the two optional model layers behind the rule parser.
//   • Jev router & matcher (OpenRouter decisions): classifies a request the
//     parser could not handle and picks a device + action. On/off is
//     independent of the Cloud LLM, so both can be active together.
//   • Cloud LLM (Anthropic / OpenAI-compatible / Apple on-device): plans
//     free-form requests, including situations ("the room is stuffy").
// Any change rebuilds both via services.reloadPlanner().
import MyHomeCore
import SwiftUI

struct AIModelsSettingsView: View {
    @AppStorage(AppSettings.jevEnabledKey) private var jevEnabled = AppSettings.defaultJevEnabled
    @AppStorage(AppSettings.plannerProviderKey) private var provider = AppSettings.defaultPlannerProvider

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var body: some View {
        Form {
            Section {
                Text(Self.routingNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How requests are handled")
            }

            Section {
                Toggle("Use Jev to route and match requests", isOn: $jevEnabled)
                if jevEnabled { JevSettingsFields(services: services) }
            } header: {
                Text("Jev router & matcher")
            } footer: {
                Text(jevEnabled ? JevSettingsFields.privacyNote : Self.jevOffNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Provider", selection: $provider) {
                    Text("None").tag(AppSettings.PlannerProvider.none)
                    Text("Anthropic API").tag(AppSettings.PlannerProvider.anthropic)
                    Text("OpenAI-compatible").tag(AppSettings.PlannerProvider.openAICompatible)
                    Text("Apple on-device (Foundation Models)").tag(AppSettings.PlannerProvider.apple)
                }
                // .id(provider): a fresh key model and field per provider/account.
                if provider.isCloud { CloudPlannerFields(services: services, provider: provider).id(provider) }
            } header: {
                Text("Cloud LLM")
            } footer: {
                Text(plannerNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onChange(of: provider) { _ in services.reloadPlanner() }
        .onChange(of: jevEnabled) { _ in services.reloadPlanner() }
    }

    // allow-hardcode: UI copy.
    static let routingNote = "1. The built-in parser handles direct commands (\u{201C}turn on the desk lamp\u{201D}) and simple questions (\u{201C}how many lights are on?\u{201D}) on this Mac. 2. If it can't, Jev (when on) classifies the request: a command → Jev picks the device and action; a question about devices → counted on this Mac; a situation (\u{201C}the room is stuffy\u{201D}) → the Cloud LLM. 3. Without Jev, the Cloud LLM gets everything the parser can't handle. Jev cannot answer free text or invent actions — situations need a Cloud LLM. Anything a model proposes is confirmed before it runs."
    // allow-hardcode: UI copy.
    static let jevOffNote = "Off: nothing is sent to Jev."

    private var plannerNote: String {
        switch provider {
        case .none:
            return "No Cloud LLM: requests the parser (and Jev) can't handle are not planned; nothing is sent anywhere."
        case .apple:
            if let note = PlannerFactory.platformNote() { return note + " Direct commands work without it." }
            if let reason = services.assistant.planner?.unavailableReason { return "Unavailable: \(reason)." }
            return "Requests the parser cannot handle are planned by the on-device model; the plan is confirmed before anything runs."
        case .anthropic, .openAICompatible:
            return "Privacy: when the parser cannot handle a request, your command and your device names, room names, kinds, capabilities and current on/off state and level are sent to the provider above. Device ids and credentials are not. The key is kept in the macOS Keychain. Plans are always confirmed before anything runs."
        }
    }
}

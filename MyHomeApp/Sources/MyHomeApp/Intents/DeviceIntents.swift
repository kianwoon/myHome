// App Intents: Siri / Shortcuts entry points. Each intent is a thin adapter
// over DeviceController / AssistantCoordinator — policy, execution and
// verification stay in the core; intents only translate parameters and
// speak the structured result. They run in-process (no extension), so they
// reach the same DeviceStore the app uses (AppServices.shared).
import AppIntents
import Foundation
import MyHomeCore

@available(macOS 14, *)
enum PowerState: String, AppEnum {
    case on, off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Power State")
    static let caseDisplayRepresentations: [PowerState: DisplayRepresentation] = [.on: "On", .off: "Off"]
}

@available(macOS 14, *)
struct SetDevicePowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Device Power"
    static let description = IntentDescription("Turns a MyHome device on or off.")

    @Parameter(title: "Device")
    var device: DeviceEntity

    @Parameter(title: "State")
    var state: PowerState

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$state) \(\.$device)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.ensureRosterLoaded()
        let result = await services.controller.perform(.power(state == .on), on: DeviceQuery(ids: [device.id]),
                                                       origin: .siri, confirmed: true)
        return .result(dialog: IntentDialog(stringLiteral: result.spokenSummary))
    }
}

@available(macOS 14, *)
struct SetDeviceLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Device Level"
    static let description = IntentDescription("Sets a device's brightness, position or fan level as a percent.")

    @Parameter(title: "Device")
    var device: DeviceEntity

    @Parameter(title: "Level (percent)")
    var level: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$device) to \(\.$level) percent")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.ensureRosterLoaded()
        let result = await services.controller.perform(.level(Percent.clamp(level)), on: DeviceQuery(ids: [device.id]),
                                                       origin: .siri, confirmed: true)
        return .result(dialog: IntentDialog(stringLiteral: result.spokenSummary))
    }
}

/// Free text through the same pipeline as the command bar: Level-1 grammar,
/// then the on-device model when available. Multi-device or model-authored
/// plans ask for confirmation through Siri before anything runs.
@available(macOS 14, *)
struct ControlHomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Home"
    static let description = IntentDescription("Runs a MyHome command such as “turn off the bedroom lights” or “set the study fan to 50%”.")

    @Parameter(title: "Command", requestValueDialog: "What should MyHome do?")
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell MyHome to \(\.$command)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.ensureRosterLoaded()
        let assistant = services.assistant
        let reply = await assistant.handle(command, origin: .siri)
        guard reply.kind == .needsConfirmation else {
            return .result(dialog: IntentDialog(stringLiteral: reply.text))
        }
        do {
            if #available(macOS 15, *) {
                try await requestConfirmation(dialog: IntentDialog(stringLiteral: reply.text))
            } else {
                try await requestConfirmation(result: .result(dialog: IntentDialog(stringLiteral: reply.text)))
            }
        } catch {
            assistant.cancelPending()
            throw error
        }
        let done = await assistant.confirmPending()
        return .result(dialog: IntentDialog(stringLiteral: done?.text ?? reply.text))
    }
}

/// Phrases Siri and Spotlight learn at install time. The metadata processor
/// enforces: only entity/enum parameters may appear, and at most ONE per
/// phrase — so the device is bound by voice and Siri prompts for the state
/// or level; the free-text intent prompts for its command.
@available(macOS 14, *)
struct MyHomeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ControlHomeIntent(),
            phrases: [
                "Control my home with \(.applicationName)",
                "Ask \(.applicationName) to control a device",
                "Tell \(.applicationName) to do something"
            ],
            shortTitle: "Control Home",
            systemImageName: "house"
        )
        AppShortcut(
            intent: SetDevicePowerIntent(),
            phrases: [
                "Set \(\.$device) power with \(.applicationName)",
                "Switch \(\.$device) with \(.applicationName)"
            ],
            shortTitle: "Set Device Power",
            systemImageName: "power"
        )
        AppShortcut(
            intent: SetDeviceLevelIntent(),
            phrases: [
                "Set \(\.$device) level with \(.applicationName)",
                "Dim \(\.$device) with \(.applicationName)"
            ],
            shortTitle: "Set Device Level",
            systemImageName: "slider.horizontal.3"
        )
    }
}

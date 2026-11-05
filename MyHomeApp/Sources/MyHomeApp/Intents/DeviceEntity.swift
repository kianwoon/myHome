// App Intents entity over the live device registry (DeviceController). Siri
// and Shortcuts resolve a spoken/typed device name through the same resolver
// the voice path uses, so "bedroom fan" means the same thing everywhere.
import AppIntents
import Foundation
import MyHomeCore

@available(macOS 14, *)
struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "MyHome Device")
    static let defaultQuery = DeviceEntityQuery()

    let id: String
    let name: String
    let room: String
    let kindLabel: String

    init(summary: DeviceSummary) {
        id = summary.id
        name = summary.name
        room = summary.room
        kindLabel = summary.kind.label
    }

    var displayRepresentation: DisplayRepresentation {
        let subtitle = room.isEmpty ? kindLabel : "\(kindLabel) · \(room)"
        return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }
}

@available(macOS 14, *)
struct DeviceEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        let services = AppServices.shared
        await services.ensureRosterLoaded()
        let wanted = Set(identifiers)
        return services.controller.summaries().filter { wanted.contains($0.id) }.map(DeviceEntity.init(summary:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [DeviceEntity] {
        let services = AppServices.shared
        await services.ensureRosterLoaded()
        let controller = services.controller
        // Only a CLEAR match answers outright; a partial one falls through to
        // the substring list so Siri asks instead of guessing.
        let resolved = DeviceEntityMatching.clearMatches(in: controller.resolve(DeviceQuery(text: string)))
        if !resolved.isEmpty {
            return resolved.map { DeviceEntity(summary: controller.summary(for: $0)) }
        }
        // Shortcuts' picker also searches by substring while typing.
        let needle = TextNormalizer.fold(string)
        return controller.summaries()
            .filter { needle.isEmpty || TextNormalizer.fold($0.name).contains(needle) || TextNormalizer.fold($0.room).contains(needle) }
            .map(DeviceEntity.init(summary:))
    }

    @MainActor
    func suggestedEntities() async throws -> [DeviceEntity] {
        let services = AppServices.shared
        await services.ensureRosterLoaded()
        return services.controller.summaries().filter(\.isControllable).map(DeviceEntity.init(summary:))
    }
}

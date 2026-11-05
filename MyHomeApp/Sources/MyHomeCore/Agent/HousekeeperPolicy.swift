// When the housekeeper asks before acting. DeviceController keeps its
// per-device veto (unreachable, unsupported); this policy decides whether a
// whole `set` runs at once or comes back as one "Go ahead?". A room's lights
// run immediately; a sweep across rooms, or a socket that may power a
// computer, asks first.
import Foundation

public struct HousekeeperPolicy: Equatable, Sendable {
    public var confirmKinds: Set<DeviceKind>
    public var maxRoomsWithoutConfirm: Int
    public var maxDevicesAcrossRoomsWithoutConfirm: Int

    public init(confirmKinds: Set<DeviceKind> = AppSettings.defaultHousekeeperConfirmKinds,
                maxRoomsWithoutConfirm: Int = AppSettings.defaultHousekeeperConfirmMaxRooms,
                maxDevicesAcrossRoomsWithoutConfirm: Int = AppSettings.defaultHousekeeperConfirmMaxDevices) {
        self.confirmKinds = confirmKinds
        self.maxRoomsWithoutConfirm = maxRoomsWithoutConfirm
        self.maxDevicesAcrossRoomsWithoutConfirm = maxDevicesAcrossRoomsWithoutConfirm
    }

    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> HousekeeperPolicy {
        HousekeeperPolicy(confirmKinds: AppSettings.housekeeperConfirmKinds(from: defaults),
                          maxRoomsWithoutConfirm: AppSettings.housekeeperConfirmMaxRooms(from: defaults),
                          maxDevicesAcrossRoomsWithoutConfirm: AppSettings.housekeeperConfirmMaxDevices(from: defaults))
    }

    /// Why one set must be confirmed first, or nil to run it now.
    public func confirmationReason(for targets: [DeviceSummary], command: DeviceCommand, handles: DeviceHandles) -> String? {
        let sensitive = targets.filter { confirmKinds.contains($0.kind) }
        if !sensitive.isEmpty {
            let names = CommandPhrasing.list(sensitive.prefix(4).map(\.name), conjunction: "and")
            return "\(names) \(sensitive.count == 1 ? "is a" : "are") \(sensitive.count == 1 ? "socket" : "sockets") that may power something important"
        }
        let rooms = Set(targets.map { handles.room(for: $0) })
        if rooms.count > maxRoomsWithoutConfirm, targets.count > maxDevicesAcrossRoomsWithoutConfirm {
            return "this touches \(targets.count) devices across \(rooms.count) rooms"
        }
        return nil
    }
}

// The decision behind Siri/Shortcuts device lookups: only a CLEAR resolution
// answers outright. Partial or ambiguous matches are suggestions, so the
// caller falls back to a candidate list and the system asks the user.
import Foundation

public enum DeviceEntityMatching {
    public static func clearMatches(in resolution: Resolution) -> [Device] {
        switch resolution {
        case .single, .set, .briturnGroup: return resolution.devices
        case .none, .ambiguous: return []
        }
    }
}

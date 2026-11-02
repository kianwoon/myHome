// baseline-guard:allow new settings source, no prior baseline
import Foundation

/// User-defaults keys and defaults shared by the Settings screen and the store.
///
/// The named constants in `DeviceStore` remain the defaults; these accessors
/// only decide whether the user has overridden them.
public enum AppSettings {
    public static let pollIntervalKey = "pollIntervalSeconds"
    public static let scanWindowKey = "scanWindowSeconds"
    public static let autoScanMinutesKey = "autoScanMinutes"
    public static let notifyOfflineKey = "notifyOnDeviceOffline"

    public static let defaultPollInterval = 10
    public static let defaultScanWindow = 35
    public static let defaultAutoScanMinutes = 10
    public static let autoScanMinutesRange = 0...120

    public static let pollIntervalRange = 5...120
    public static let scanWindowRange = 15...60

    public static func pollInterval(from defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.object(forKey: pollIntervalKey) as? Int
        let seconds = stored ?? defaultPollInterval
        return TimeInterval(min(max(seconds, pollIntervalRange.lowerBound), pollIntervalRange.upperBound))
    }

    public static func scanWindow(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: scanWindowKey) as? Int
        return min(max(stored ?? defaultScanWindow, scanWindowRange.lowerBound), scanWindowRange.upperBound)
    }

    /// Minutes between automatic Briturn scans; 0 = off, otherwise at least 1.
    public static func autoScanMinutes(from defaults: UserDefaults = .standard) -> Int {
        clampAutoScanMinutes(defaults.object(forKey: autoScanMinutesKey) as? Int ?? defaultAutoScanMinutes)
    }

    public static func clampAutoScanMinutes(_ minutes: Int) -> Int {
        min(max(minutes, autoScanMinutesRange.lowerBound), autoScanMinutesRange.upperBound)
    }

    public static func notificationsEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: notifyOfflineKey)
    }
}

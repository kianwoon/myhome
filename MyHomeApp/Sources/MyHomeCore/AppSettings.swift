// baseline-guard:allow new settings source, no prior baseline
import Foundation

/// User-defaults keys and defaults shared by the Settings screen and the store.
///
/// The named constants in `DeviceStore` remain the defaults; these accessors
/// only decide whether the user has overridden them.
public enum AppSettings {
    public static let pollIntervalKey = "pollIntervalSeconds"
    public static let scanWindowKey = "scanWindowSeconds"
    public static let notifyOfflineKey = "notifyOnDeviceOffline"

    public static let defaultPollInterval = 10
    public static let defaultScanWindow = 35

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

    public static func notificationsEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: notifyOfflineKey)
    }
}

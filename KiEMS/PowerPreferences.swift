import Foundation

/// Whether the Mac stays awake while jobs run -- chosen in the Settings window, kept in the user's
/// defaults, and applied by JobScheduler (see updatePowerActivity()) whenever a job starts, finishes,
/// pauses or resumes, or this preference changes.
enum PowerPreferences {
    private static let keepAwakeKey = "KeepAwakeWhileJobsRun"

    static var keepAwakeWhileJobsRun: Bool {
        get { UserDefaults.standard.object(forKey: keepAwakeKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: keepAwakeKey)
            JobScheduler.shared.updatePowerActivity()
        }
    }

    /// macOS has no public API to switch the system into High Power Mode (or out of Low Power Mode),
    /// so the most an app can ask for is idle sleep held off, no App Nap or timer coalescing, and
    /// user-initiated scheduling priority.
    static let activityOptions: ProcessInfo.ActivityOptions = [
        .userInitiated, .idleSystemSleepDisabled, .latencyCritical,
    ]
}

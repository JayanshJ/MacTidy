import Foundation

/// Writes and removes the launchd `LaunchAgent` plist that triggers
/// scheduled cleanups. One plist (`com.jayansh.mactidy.plist`) covers every
/// enabled job: launchd fires on the *earliest* next calendar match across
/// all jobs, and the app decides at fire time which jobs are actually due.
///
/// The agent relaunches MacTidy with a `--run-scheduled` argument so cleanups
/// happen even when the app is closed. The app runs due jobs headlessly,
/// records to `CleanupLog`/`TrashLog`, and the agent is not kept alive (it
/// runs once per fire, not as a persistent daemon).
public enum LaunchAgentWriter {
    public static let label = "com.jayansh.mactidy"
    public static let runScheduledFlag = "--run-scheduled"

    /// The conventional LaunchAgents path for the current user.
    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/com.jayansh.mactidy.plist")
    }

    /// Writes (or replaces) the plist for the given jobs. When no jobs are
    /// enabled, removes the plist instead — a no-schedules state must not
    /// leave a dead agent behind. Returns true on a filesystem change.
    @discardableResult
    public static func write(for jobs: [ScheduledJob]) throws -> Bool {
        let enabled = jobs.filter { $0.enabled && !$0.categories.isEmpty }
        guard !enabled.isEmpty else {
            return remove()
        }
        let plist = try makePlist(for: enabled)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist as Any, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        return true
    }

    /// Removes the plist if present. Returns true when something was deleted.
    @discardableResult
    public static func remove() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plistURL.path) else { return false }
        try? fm.removeItem(at: plistURL)
        return true
    }

    /// Builds the plist dictionary for the enabled jobs. Exposed for testing.
    public static func makePlist(for enabledJobs: [ScheduledJob]) throws -> [String: Any] {
        // The executable is this app's binary; launchd re-launches it with
        // the run-scheduled flag so the app performs the cleanup headlessly.
        let executablePath = Bundle.main.bundlePath + "/Contents/MacOS/MacTidy"
        var calIntervals: [[String: Int]] = []
        for job in enabledJobs where !job.categories.isEmpty {
            switch job.cadence {
            case .daily:
                calIntervals.append(["Hour": job.hour])
            case .weekly:
                // StartCalendarInterval uses 1=Sunday … 7=Saturday.
                calIntervals.append(["Weekday": job.weekday, "Hour": job.hour])
            case .monthly:
                calIntervals.append(["Day": job.dayOfMonth, "Hour": job.hour])
            }
        }
        // launchd accepts a single dict (fires once per match) or an array
        // (fires on each). An array deduplicates naturally; if only one, keep
        // the single-dict form for readability.
        let intervalValue: Any
        if calIntervals.count == 1 {
            intervalValue = calIntervals[0]
        } else {
            intervalValue = calIntervals
        }
        return [
            "Label": label,
            "ProgramArguments": [executablePath, runScheduledFlag],
            "StartCalendarInterval": intervalValue,
            "RunAtLoad": false,
            "KeepAlive": false,
        ]
    }
}
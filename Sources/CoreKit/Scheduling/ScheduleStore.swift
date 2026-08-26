import Foundation

/// How often a scheduled cleanup job fires. launchd `StartCalendarInterval`
/// maps these to a calendar match: daily = a specific hour every day,
/// weekly = a specific weekday + hour, monthly = a specific day-of-month
/// + hour.
public enum ScheduleCadence: String, Codable, Sendable, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
}

/// One scheduled cleanup job. A cadence plus the subset of *safe*
/// (`isPreselectable`) categories to auto-trash on each fire. The category
/// subset is deliberately restricted to preselectable categories — automated
/// runs never touch suggest-only categories (node_modules, iOS backups, app
/// support, large files) or Docker/uninstall. The existing destructive path
/// (`SafePathPolicy` + `Trasher`) still vets every item on top of this.
public struct ScheduledJob: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var enabled: Bool
    public var cadence: ScheduleCadence
    /// Hour of the day (0–23) at which the job fires.
    public var hour: Int
    /// Weekday (1=Sunday … 7=Saturday) for weekly jobs; ignored otherwise.
    public var weekday: Int
    /// Day-of-month (1–28) for monthly jobs; ignored otherwise. Capped at 28
    /// so every month has that day (avoids the "Feb 30 doesn't exist" gap).
    public var dayOfMonth: Int
    /// Safe categories to auto-trash. Only `isPreselectable` categories are
    /// accepted; others are filtered out on load.
    public var categories: Set<Category>
    /// ISO-8601 timestamp of the last fire, or nil if never run.
    public var lastRun: Date?
    /// Computed next fire time, or nil when disabled.
    public var nextRun: Date?

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        cadence: ScheduleCadence = .weekly,
        hour: Int = 3,
        weekday: Int = 7,
        dayOfMonth: Int = 1,
        categories: Set<Category> = [],
        lastRun: Date? = nil,
        nextRun: Date? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.cadence = cadence
        self.hour = max(0, min(23, hour))
        self.weekday = max(1, min(7, weekday))
        self.dayOfMonth = max(1, min(28, dayOfMonth))
        // Defensive: only keep safe categories even if a hand-edited file
        // sneaks in a suggest-only one.
        self.categories = categories.filter { $0.isPreselectable }
        self.lastRun = lastRun
        self.nextRun = nextRun
    }
}

/// Persists the scheduled-job list as JSON in the app's Application Support
/// directory. The launchd plist is written separately by `LaunchAgentWriter`;
/// this store is the source of truth for *what* to run, the plist is only the
/// *when* trigger.
public final class ScheduleStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.jayansh.mactidy.schedule-store")

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = Self.supportDirectory()
            self.fileURL = support.appending(path: "schedules.json")
        }
    }

    public func load() -> [ScheduledJob] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let jobs = try? JSONDecoder().decode([ScheduledJob].self, from: data)
            else { return [] }
            return jobs
        }
    }

    public func save(_ jobs: [ScheduledJob]) {
        queue.sync {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try? JSONEncoder().encode(jobs)
            try? data?.write(to: fileURL, options: .atomic)
        }
    }

    private static func supportDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Library/Application Support/MacTidy")
    }
}

/// Computes the next fire `Date` for a job from a reference "now". Pure —
/// testable without the event loop. Returns nil when the job is disabled.
public enum SchedulePlanner {
    public static func nextRun(for job: ScheduledJob, after now: Date) -> Date? {
        guard job.enabled else { return nil }
        let cal = Calendar.current
        // Build only the matching components for the cadence — carrying
        // year/month/day from `now` into a weekly/monthly match makes
        // `nextDate(matching:)` pin to the current day and return `now`'s
        // time instead of the next matching weekday/day-of-month.
        var comps = DateComponents()
        comps.minute = 0
        comps.second = 0
        comps.hour = job.hour
        switch job.cadence {
        case .daily:
            break  // hour only — fires every day at job.hour
        case .weekly:
            comps.weekday = job.weekday
        case .monthly:
            comps.day = job.dayOfMonth
        }
        // `.nextTime` finds the next date at or after `now` matching the
        // given components, so a weekly job at 03:00 whose hour already
        // passed today correctly rolls to next week.
        return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
            ?? cal.date(byAdding: .day, value: 1, to: now)
    }
}
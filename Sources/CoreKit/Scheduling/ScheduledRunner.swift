import Foundation

/// The result of one scheduled fire: which jobs ran and the executor outcome
/// (trashed/skipped/reclaimed). The app layer records the outcome to
/// `TrashLog`/`CleanupLog` via its existing `recordOutcome` path so the
/// TrashRecord conversion + size lookup stay in one place.
public struct ScheduledRunResult: Sendable {
    public let firedJobs: [UUID]
    public let plan: DeletionPlan
    public let outcome: DeletionOutcome
    /// A scan-only job fired: the caller runs a full read-only scan and
    /// records it to scan history, after any cleanup so it shows the result.
    public let wantsFullScan: Bool
    public init(firedJobs: [UUID], plan: DeletionPlan, outcome: DeletionOutcome, wantsFullScan: Bool = false) {
        self.firedJobs = firedJobs
        self.plan = plan
        self.outcome = outcome
        self.wantsFullScan = wantsFullScan
    }
}

/// Runs the scheduled cleanup: for each due job, rescans its safe
/// categories, builds a `DeletionPlan` from the results, and runs it through
/// the existing destructive path (`DeletionExecutor` + `SafePathPolicy` +
/// `Trasher`). **Must not bypass `SafePathPolicy`** — automated runs get the
/// same deny-by-default, per-item fail-closed classification as manual ones.
/// Never runs Docker shell actions or uninstall; never touches suggest-only
/// categories.
///
/// The scanner and executor are injected so the pure logic is testable
/// without docker/filesystem state. Logging is left to the caller (AppState)
/// so the `TrashedRecord → TrashRecord` conversion stays single-sourced.
public enum ScheduledRunner {
    /// Type-erased scan closure so tests can feed fixture `CategoryResult`s
    /// without running a real filesystem scan.
    public typealias ScanCategories = @Sendable (Set<Category>) async -> [CategoryResult]

    public static func run(
        jobs: [ScheduledJob],
        now: Date,
        scan: ScanCategories,
        executor: DeletionExecutor
    ) async -> ScheduledRunResult? {
        // A job is "due" when it's runnable (enabled, and a clean job has at
        // least one safe category) and its nextRun is at or before `now` (or
        // has never been computed — covers the first fire after enabling).
        let due = jobs.filter { job in
            guard job.isRunnable else { return false }
            guard let next = job.nextRun else { return true }
            return next <= now
        }
        guard !due.isEmpty else { return nil }
        let wantsFullScan = due.contains { $0.mode == .scanOnly }

        // Union of categories across due *clean* jobs — one scan, not one per
        // job. A scan-only job never contributes, even with categories set.
        let categories: Set<Category> = Set(due.filter { $0.mode == .clean }.flatMap { $0.categories })
        guard !categories.isEmpty else {
            return ScheduledRunResult(firedJobs: due.map(\.id), plan: DeletionPlan(items: []),
                                      outcome: DeletionOutcome(trashed: [], skipped: [], reclaimedBytes: 0),
                                      wantsFullScan: wantsFullScan)
        }
        let results = await scan(categories)
        // Only the requested categories; the scan may return others (tests),
        // so filter to be precise.
        let items = results.filter { categories.contains($0.category) }
            .flatMap(\.items)
            // Per-item gate: a safe category can still hold Caution/Danger
            // registry items (VM disks, models); automated runs never touch them.
            .filter(\.isPreselectable)

        let plan = DeletionPlan(items: items)
        let outcome = executor.execute(plan)
        return ScheduledRunResult(firedJobs: due.map(\.id), plan: plan, outcome: outcome,
                                  wantsFullScan: wantsFullScan)
    }
}
import Foundation
import Testing
@testable import CoreKit

/// `ScheduleStore`, `SchedulePlanner`, `LaunchAgentWriter`, and
/// `ScheduledRunner` — the scheduled-cleanup subsystem.
@Suite("Scheduled cleanup")
struct SchedulerTests {
    // MARK: - ScheduleStore

    @Test func storeRoundTripsJobs() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-sched-\(UUID().uuidString)/schedules.json")
        let store = ScheduleStore(fileURL: tmp)
        let jobs = [
            ScheduledJob(cadence: .daily, hour: 2, categories: [.userCaches, .homebrewCache]),
            ScheduledJob(enabled: false, cadence: .weekly, hour: 3, weekday: 6,
                        categories: [.devCaches]),
        ]
        store.save(jobs)
        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded[0].categories == [.userCaches, .homebrewCache])
        #expect(loaded[1].enabled == false)
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    @Test func storeDropsSuggestOnlyCategoriesOnLoad() throws {
        // A job that sneakily includes node_modules (suggest-only) must have
        // it filtered out — automated runs never touch suggest-only.
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-sched-\(UUID().uuidString)/schedules.json")
        let store = ScheduleStore(fileURL: tmp)
        let jobs = [ScheduledJob(categories: [.userCaches, .nodeModules, .bigFiles])]
        store.save(jobs)
        let loaded = store.load()
        #expect(loaded.count == 1)
        // nodeModules + bigFiles are suggest-only → dropped.
        #expect(loaded[0].categories == [.userCaches])
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    // MARK: - SchedulePlanner

    @Test func nextRunRespectsHourAndWeekday() {
        // Wed 2026-01-14 10:00 → weekly job on Saturday (7) at 03:00 fires
        // Sat 2026-01-17 03:00.
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 14,
                                                hour: 10, weekday: 4))!
        let job = ScheduledJob(cadence: .weekly, hour: 3, weekday: 7, categories: [.userCaches])
        let next = SchedulePlanner.nextRun(for: job, after: now)
        let nextComps = cal.dateComponents([.year, .month, .day, .hour, .weekday], from: next!)
        #expect(nextComps.weekday == 7)
        #expect(nextComps.hour == 3)
    }

    @Test func nextRunNilWhenDisabled() {
        let job = ScheduledJob(enabled: false, cadence: .daily, hour: 3, categories: [.userCaches])
        #expect(SchedulePlanner.nextRun(for: job, after: Date()) == nil)
    }

    // MARK: - LaunchAgentWriter

    @Test func dailyJobProducesHourOnlyInterval() throws {
        let job = ScheduledJob(cadence: .daily, hour: 2, categories: [.userCaches])
        let plist = try LaunchAgentWriter.makePlist(for: [job])
        let interval = plist["StartCalendarInterval"] as? [String: Int]
        #expect(interval?["Hour"] == 2)
        #expect(plist["KeepAlive"] as? Bool == false)
        #expect((plist["ProgramArguments"] as? [String])?.last == LaunchAgentWriter.runScheduledFlag)
    }

    @Test func weeklyJobProducesWeekdayAndHour() throws {
        let job = ScheduledJob(cadence: .weekly, hour: 3, weekday: 6, categories: [.devCaches])
        let plist = try LaunchAgentWriter.makePlist(for: [job])
        let interval = plist["StartCalendarInterval"] as? [String: Int]
        #expect(interval?["Weekday"] == 6)
        #expect(interval?["Hour"] == 3)
    }

    @Test func multipleJobsUseAnArrayOfIntervals() throws {
        let jobs = [
            ScheduledJob(cadence: .daily, hour: 2, categories: [.userCaches]),
            ScheduledJob(cadence: .weekly, hour: 3, weekday: 7, categories: [.devCaches]),
        ]
        let plist = try LaunchAgentWriter.makePlist(for: jobs)
        let intervals = plist["StartCalendarInterval"] as? [[String: Int]]
        #expect(intervals?.count == 2)
    }

    @Test func emptyJobsRemoveReturnsFalseWhenAbsent() {
        // No plist written yet → remove() is a no-op returning false.
        // Use the real path but ensure it's gone first (cleanup only).
        try? FileManager.default.removeItem(at: LaunchAgentWriter.plistURL)
        #expect(LaunchAgentWriter.remove() == false)
    }

    // MARK: - ScheduledRunner

    @Test func runnerSkipsDisabledAndEmptyJobs() async {
        let due = ScheduledJob(cadence: .daily, hour: 0, categories: [.userCaches],
                               nextRun: Date().addingTimeInterval(-60))
        let disabled = ScheduledJob(enabled: false, cadence: .daily, hour: 0,
                                    categories: [.userCaches], nextRun: Date().addingTimeInterval(-60))
        let empty = ScheduledJob(cadence: .daily, hour: 0, categories: [],
                                 nextRun: Date().addingTimeInterval(-60))
        let result = await ScheduledRunner.run(
            jobs: [due, disabled, empty], now: Date(),
            scan: { _ in [CategoryResult(category: .userCaches, items: [])] },
            executor: DeletionExecutor(policy: SafePathPolicy()))
        // Only `due` fired.
        #expect(result?.firedJobs == [due.id])
        #expect(result?.outcome.trashed.isEmpty ?? true)
    }

    @Test func runnerTrashesDueItems() async throws {
        // A real tmp file so Trasher can actually trash it and the policy
        // allows it (inside the tmp root, which we pass as an allowed root).
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-sched-run-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let file = sandbox.appending(path: "cache.bin")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let item = ScanItem(url: file, sizeBytes: 1, isDirectory: false, category: .userCaches)
        let job = ScheduledJob(cadence: .daily, hour: 0, categories: [.userCaches],
                               nextRun: Date().addingTimeInterval(-60))
        // Inject the item via the scan closure; the executor trashes through
        // SafePathPolicy with the sandbox as an allowed root.
        let result = await ScheduledRunner.run(
            jobs: [job], now: Date(),
            scan: { _ in [CategoryResult(category: .userCaches, items: [item])] },
            executor: DeletionExecutor(policy: SafePathPolicy(extraAllowedRoots: [sandbox])))
        #expect(result?.firedJobs == [job.id])
        #expect(result?.outcome.trashed.count == 1)
        #expect(result?.outcome.skipped.isEmpty ?? true)
    }

    @Test func runnerNeverTrashesSuggestOnlyCategories() async throws {
        // Even if a scan somehow returns node_modules items, a job scoped to
        // safe categories must not include them. Here the job is userCaches,
        // so node_modules items from the scan are filtered out by the category
        // filter in run().
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-sched-suggest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let file = sandbox.appending(path: "node_mod.bin")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let item = ScanItem(url: file, sizeBytes: 1, isDirectory: false, category: .nodeModules)
        let job = ScheduledJob(cadence: .daily, hour: 0, categories: [.userCaches],
                               nextRun: Date().addingTimeInterval(-60))
        let result = await ScheduledRunner.run(
            jobs: [job], now: Date(),
            scan: { _ in [
                CategoryResult(category: .userCaches, items: []),
                CategoryResult(category: .nodeModules, items: [item]),
            ] },
            executor: DeletionExecutor(policy: SafePathPolicy(extraAllowedRoots: [sandbox])))
        // node_modules is not in the job's categories → its items are not in
        // the plan → nothing trashed.
        #expect(result?.outcome.trashed.isEmpty ?? true)
    }
}
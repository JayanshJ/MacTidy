import Foundation
import Testing
@testable import CoreKit

/// Feature 5: scan-only schedules, What Changed?, Disk Map locations,
/// Disk Accounting links and the Downloads installers nudge.
@Suite("Space investigation and scan-only schedules")
struct SpaceInvestigationTests {
    // MARK: - Scan-only schedules

    @Test func oldScheduleFilesDecodeAsCleanJobs() throws {
        // A schedules.json written before `mode` existed.
        let json = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","enabled":true,"cadence":"weekly",
          "hour":3,"weekday":7,"dayOfMonth":1,"categories":["userCaches"]}]
        """
        let jobs = try JSONDecoder().decode([ScheduledJob].self, from: Data(json.utf8))
        #expect(jobs.count == 1)
        #expect(jobs[0].mode == .clean)
        #expect(jobs[0].categories == [.userCaches])
    }

    @Test func modeRoundTripsThroughTheStore() {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-sched-\(UUID().uuidString)/schedules.json")
        let store = ScheduleStore(fileURL: tmp)
        store.save([ScheduledJob(mode: .scanOnly, cadence: .daily)])
        #expect(store.load().first?.mode == .scanOnly)
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    @Test func scanOnlyJobWithoutCategoriesIsRunnable() throws {
        let scanOnly = ScheduledJob(mode: .scanOnly, cadence: .daily)
        let emptyClean = ScheduledJob(mode: .clean, cadence: .daily)
        #expect(scanOnly.isRunnable)
        #expect(!emptyClean.isRunnable)
        #expect(!ScheduledJob(enabled: false, mode: .scanOnly).isRunnable)
        let plist = try LaunchAgentWriter.makePlist(for: [scanOnly])
        #expect(plist["StartCalendarInterval"] != nil)
    }

    @Test func scanOnlyJobNeverBuildsAPlan() async {
        // Even a hand-edited scan-only job with categories must not clean.
        let job = ScheduledJob(mode: .scanOnly, cadence: .daily, categories: [.userCaches])
        let item = ScanItem(url: URL(fileURLWithPath: "/tmp/never"), sizeBytes: 1, isDirectory: false,
                            category: .userCaches)
        let result = await ScheduledRunner.run(
            jobs: [job], now: Date(),
            scan: { _ in
                Issue.record("A scan-only job must not run the cleanup scan")
                return [CategoryResult(category: .userCaches, items: [item])]
            },
            executor: DeletionExecutor(policy: SafePathPolicy()))
        #expect(result?.firedJobs == [job.id])
        #expect(result?.wantsFullScan == true)
        #expect(result?.plan.isEmpty == true)
        #expect(result?.outcome.trashed.isEmpty == true)
    }

    @Test func mixedJobsCleanOnlyCleanCategories() async {
        let clean = ScheduledJob(mode: .clean, cadence: .daily, categories: [.homebrewCache])
        let scanOnly = ScheduledJob(mode: .scanOnly, cadence: .daily, categories: [.userCaches])
        let requested = LockedBox<Set<CoreKit.Category>>([])
        let result = await ScheduledRunner.run(
            jobs: [clean, scanOnly], now: Date(),
            scan: { categories in
                requested.set(categories)
                return []
            },
            executor: DeletionExecutor(policy: SafePathPolicy()))
        #expect(requested.get() == [.homebrewCache])
        #expect(result?.wantsFullScan == true)
        #expect(Set(result?.firedJobs ?? []) == [clean.id, scanOnly.id])
    }

    // MARK: - What Changed?

    private func snapshot(daysAgo: Double, now: Date, reclaimable: Int64 = 0,
                          categories: [String: Int64], folders: [String: Int64]? = nil) -> ScanSnapshot {
        ScanSnapshot(date: now.addingTimeInterval(-daysAgo * 86_400), reclaimableBytes: reclaimable,
                     itemCount: 0, categories: categories, folders: folders)
    }

    @Test func whatChangedComparesWithinTheChosenWindow() {
        let now = Date()
        let gb: Int64 = 1_000_000_000
        let history = [
            snapshot(daysAgo: 60, now: now, reclaimable: 1 * gb, categories: ["userCaches": 1 * gb]),
            snapshot(daysAgo: 5, now: now, reclaimable: 2 * gb, categories: ["userCaches": 2 * gb]),
            snapshot(daysAgo: 0, now: now, reclaimable: 3 * gb, categories: ["userCaches": 2 * gb + 300_000_000]),
        ]
        let week = WhatChanged.make(history: history, cleanups: [], items: [], window: .week, now: now)
        #expect(week.scans.count == 2)
        #expect(week.reclaimableDelta == 1 * gb)
        // 300 MB is below the Overview's 1 GB bar but shows here.
        guard case .growing(let nudges) = week.growth else { Issue.record("expected growth"); return }
        #expect(nudges.first?.delta == 300_000_000)

        let quarter = WhatChanged.make(history: history, cleanups: [], items: [], window: .quarter, now: now)
        #expect(quarter.scans.count == 3)
        guard case .growing(let longer) = quarter.growth else { Issue.record("expected growth"); return }
        #expect(longer.first?.delta == 1 * gb + 300_000_000)
    }

    @Test func whatChangedNeverComparesOutsideThePeriod() {
        let now = Date()
        let history = [
            snapshot(daysAgo: 60, now: now, categories: ["userCaches": 1_000_000_000]),
            snapshot(daysAgo: 0, now: now, categories: ["userCaches": 5_000_000_000]),
        ]
        let week = WhatChanged.make(history: history, cleanups: [], items: [], window: .week, now: now)
        #expect(week.growth == .noHistory)
        #expect(week.comparedWith == nil)
        let quarter = WhatChanged.make(history: history, cleanups: [], items: [], window: .quarter, now: now)
        #expect(quarter.comparedWith != nil)
    }

    @Test func locatorSkipsHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        let items = [
            ScanItem(url: home.appending(path: "Downloads/a.dmg"), sizeBytes: 1, isDirectory: false, category: .bigFiles),
            ScanItem(url: home.appending(path: "Developer/b.zip"), sizeBytes: 1, isDirectory: false, category: .bigFiles),
        ]
        let nudge = GrowthNudge(name: "Big files", place: .category(.bigFiles), delta: 1, current: 1, since: Date())
        #expect(ChangeLocator.folder(for: nudge, results: [CategoryResult(category: .bigFiles, items: items)],
                                     elsewhere: [], home: home) == nil)
    }

    @Test func whatChangedWithoutHistorySaysSo() {
        let report = WhatChanged.make(history: [], cleanups: [], items: [], window: .month)
        #expect(report.growth == .noHistory)
        #expect(report.comparedWith == nil)
        #expect(report.reclaimableDelta == nil)
    }

    @Test func returnedItemsRespectTheWindow() {
        let now = Date()
        let url = URL(fileURLWithPath: "/Users/me/Developer/app/node_modules")
        let item = ScanItem(url: url, sizeBytes: 200 * 1024 * 1024, isDirectory: true, category: .nodeModules)
        let cleanup = CleanupEntry(date: now.addingTimeInterval(-20 * 86_400), kind: .deletion,
                                   reclaimedBytes: 1, itemCount: 1, paths: [url.standardizedFileURL.path])
        #expect(WhatChanged.make(history: [], cleanups: [cleanup], items: [item], window: .week, now: now).returned.isEmpty)
        #expect(WhatChanged.make(history: [], cleanups: [cleanup], items: [item], window: .month, now: now).returned.count == 1)
    }

    @Test func growthNudgesKeepTheirFolder() {
        let now = Date()
        let gb: Int64 = 1_000_000_000
        let history = [
            snapshot(daysAgo: 3, now: now, categories: ["appSupport": 1 * gb], folders: ["appSupport:Slack": 1 * gb]),
            snapshot(daysAgo: 0, now: now, categories: ["appSupport": 4 * gb], folders: ["appSupport:Slack": 4 * gb]),
        ]
        guard case .growing(let nudges) = ScanHistory.growthReport(in: history) else {
            Issue.record("expected growth"); return
        }
        #expect(nudges.first?.folder == "Slack")
    }

    // MARK: - Disk Map locations

    @Test func locatorFindsTheOwnersFolder() {
        let base = "/Users/me/Library/Application Support/Slack"
        let items = [
            ScanItem(url: URL(fileURLWithPath: "\(base)/Cache"), sizeBytes: 1, isDirectory: true,
                     category: .appSupport, detail: "Slack"),
            ScanItem(url: URL(fileURLWithPath: "\(base)/Code Cache"), sizeBytes: 1, isDirectory: true,
                     category: .appSupport, detail: "Slack"),
            ScanItem(url: URL(fileURLWithPath: "/Users/me/Library/Application Support/Other/Cache"),
                     sizeBytes: 1, isDirectory: true, category: .appSupport, detail: "Other"),
        ]
        let nudge = GrowthNudge(name: "Slack", place: .category(.appSupport), delta: 1, current: 1,
                                since: Date(), folder: "Slack")
        let folder = ChangeLocator.folder(for: nudge, results: [CategoryResult(category: .appSupport, items: items)],
                                          elsewhere: [])
        #expect(folder?.path == base)
    }

    @Test func locatorRefusesUselessAncestors() {
        let items = [
            ScanItem(url: URL(fileURLWithPath: "/Users/a/x"), sizeBytes: 1, isDirectory: true),
            ScanItem(url: URL(fileURLWithPath: "/Users/b/y"), sizeBytes: 1, isDirectory: true),
        ]
        #expect(ChangeLocator.commonFolder(of: items) == nil)
        #expect(ChangeLocator.commonFolder(of: []) == nil)
        let file = ScanItem(url: URL(fileURLWithPath: "/Users/a/Downloads/big.dmg"), sizeBytes: 1, isDirectory: false)
        #expect(ChangeLocator.folder(for: file).path == "/Users/a/Downloads")
    }

    @Test func locatorFindsHandledElsewhereByRule() {
        let item = ScanItem(url: URL(fileURLWithPath: "/Users/me/Library/Containers/com.docker.docker/Data"),
                            sizeBytes: 1, isDirectory: true, finding: "docker")
        let nudge = GrowthNudge(name: "Docker", place: .handledElsewhere, delta: 1, current: 1,
                                since: Date(), folder: "docker")
        #expect(ChangeLocator.folder(for: nudge, results: [], elsewhere: [item])?.path == item.url.path)
        let other = GrowthNudge(name: "Steam", place: .handledElsewhere, delta: 1, current: 1,
                                since: Date(), folder: "steam")
        #expect(ChangeLocator.folder(for: other, results: [], elsewhere: [item]) == nil)
    }

    // MARK: - Disk Accounting links

    @Test func homePartsSplitTrashOutWithoutDoubleCounting() {
        let home = URL(fileURLWithPath: "/Users/me")
        let parts = DiskAccounting.homeParts(home: home, children: [
            (home.appending(path: "Library"), 10),
            (home.appending(path: ".Trash"), 5),
            (home.appending(path: "Documents"), 3),
            (home.appending(path: "Developer"), 2),
        ])
        #expect(parts.reduce(0) { $0 + $1.bytes } == 20)
        #expect(parts.first { $0.name == "Trash" }?.destination == .trash)
        #expect(parts.first { $0.name == "Other home files" }?.bytes == 5)
        #expect(parts.first { $0.name == "Home Library" }?.destination == .folder(home.appending(path: "Library")))
        // No Trash row when it's empty or unreadable.
        #expect(!DiskAccounting.homeParts(home: home, children: [(home.appending(path: "Library"), 1)])
            .contains { $0.name == "Trash" })
    }

    // MARK: - Downloads hygiene

    @Test func installersNudgeSumsOldInstallers() {
        let items = [
            ScanItem(url: URL(fileURLWithPath: "/Users/me/Downloads/a.dmg"), sizeBytes: 100, isDirectory: false,
                     category: .oldInstallers),
            ScanItem(url: URL(fileURLWithPath: "/Users/me/Downloads/b.pkg"), sizeBytes: 50, isDirectory: false,
                     category: .oldInstallers),
        ]
        let results = [CategoryResult(category: .oldInstallers, items: items)]
        #expect(DownloadsHygiene.nudge(results: results) == .init(count: 2, bytes: 150))
        #expect(DownloadsHygiene.nudge(results: results, minimumBytes: 1_000) == nil)
        #expect(DownloadsHygiene.nudge(results: []) == nil)
    }
}

/// Minimal thread-safe box for capturing values from `@Sendable` closures.
private final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

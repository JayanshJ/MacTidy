import Foundation
import Observation
import CoreKit

@MainActor
@Observable
final class AppState {
    var fdaGranted = FullDiskAccess.isGranted

    /// Background space watcher: quick checks on a fixed cadence + pile-up
    /// notifications. Owned here so Settings can bind its toggles and the
    /// menu bar panel can read its summary.
    let monitor = SpaceMonitor()

    /// Self-update: checks GitHub Releases for a newer MacTidy and installs
    /// it in place. Owned here so Settings can bind it and the launch check
    /// can run from RootView.
    let updates = UpdateManager()

    /// Dry-run is the app-wide default; every confirmation sheet shows the
    /// toggle. Persisted so it survives relaunches.
    var dryRun: Bool {
        didSet { UserDefaults.standard.set(dryRun, forKey: "MacTidy.dryRun") }
    }

    /// Extra roots the user has allow-listed in Settings, applied to every
    /// destructive action in addition to the policy's built-in roots.
    var extraAllowedRoots: [URL] {
        didSet { persistExtraAllowedRoots() }
    }

    /// Rescan the cleanup categories automatically when the app launches.
    var autoScanOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoScanOnLaunch, forKey: "MacTidy.autoScanOnLaunch") }
    }

    /// Days of log history to keep. 0 = keep everything (bounded only by the
    /// logs' max-entry caps). Applied at launch and when changed in Settings.
    var logRetentionDays: Int {
        didSet {
            UserDefaults.standard.set(logRetentionDays, forKey: "MacTidy.logRetentionDays")
            applyLogRetention()
        }
    }

    /// AI advisor configuration (provider, model, base URL, privacy toggle).
    /// Persisted in UserDefaults as JSON. The API key is NOT stored here — it
    /// lives in the Keychain via `KeychainHelper`.
    var aiConfig: AIConfig {
        didSet { persistAIConfig() }
    }
    /// Whether the current pass's AI query is in flight (command bar spinner).
    var isAIThinking = false
    /// The most recent AI reasoning string, surfaced with the plan.
    var lastAIReasoning: String?

    var categoryResults: [CategoryResult] = []
    var isScanningCategories = false
    var scanStatus: String = ""
    /// Human-readable progress for the current category scan ("Scanning User caches…").
    var scanProgress: String = ""
    /// Completed vs total category count for the running scan, drives the
    /// determinate progress bar on the Overview.
    var scanCompleted: Int = 0
    var scanTotal: Int = 0

    /// Everything MacTidy has trashed, newest first. Drives the "Recently
    /// Trashed" view and the post-cleanup Undo toast.
    var recentTrashed: [TrashRecord] = []
    /// The most recent real (non-dry-run) outcome, for the Undo toast.
    var lastUndoableOutcome: (records: [TrashRecord], label: String)?

    /// The first-ever real cleanup milestone, for the one-time celebration
    /// overlay. Nil until the user's first non-dry-run cleanup that actually
    /// frees space, and only set once (persisted) — so it fires exactly once
    /// ever, not on every cleanup.
    var firstReclaimMilestone: Int64?

    /// Completed cleanups, newest first — the honest reclaim-over-time log.
    var cleanupHistory: [CleanupEntry] = []

    /// Recent scan snapshots, newest first — drives the reclaimable trend.
    var scanHistory: [ScanSnapshot] = []

    // MARK: - Guided flow state

    /// The current phase of the guided cleanup wizard.
    var flowPhase: FlowPhase = .welcome
    /// The ranked queue of actions the wizard walks through, one at a time.
    var flowQueue: [FlowAction] = []
    /// Index into `flowQueue` of the action currently under review.
    var flowIndex: Int = 0
    /// The action currently under review (or nil if past the end / not in review).
    var flowCurrent: FlowAction? { flowQueue.indices.contains(flowIndex) ? flowQueue[flowIndex] : nil }
    /// Whether the current pass is the dry preview or the real cleanup.
    var flowPass: CleanPass = .dry
    /// The most recent applied outcome, shown briefly on the applying screen.
    var flowLastOutcome: DeletionOutcome?
    /// Apps + leftovers scanned during the flow, for uninstall action cards.
    var flowApps: [(app: InstalledApp, leftovers: [ScanItem])] = []
    /// Launch items scanned during the flow, for disable action cards.
    var flowLaunchItems: [LaunchItem] = []
    /// Items the user skipped during this pass — suppressed from re-surfacing
    /// until the queue is rebuilt.
    private var flowSkipped: Set<String> = []

    /// The scan task, kept so the UI can cancel an in-flight scan.
    private var scanTask: Task<Void, Never>?

    private let trashLog: TrashLog
    private let cleanupLog: CleanupLog
    private let scanHistoryStore: ScanHistory
    private let lastScanURL: URL

    init(
        trashLog: TrashLog = .shared,
        cleanupLog: CleanupLog = .shared,
        scanHistory: ScanHistory = .shared
    ) {
        self.trashLog = trashLog
        self.cleanupLog = cleanupLog
        self.scanHistoryStore = scanHistory
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacTidy")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.lastScanURL = support.appending(path: "last-scan.json")
        self.dryRun = UserDefaults.standard.object(forKey: "MacTidy.dryRun") as? Bool ?? true
        self.extraAllowedRoots = Self.loadExtraAllowedRoots()
        self.autoScanOnLaunch = UserDefaults.standard.object(forKey: "MacTidy.autoScanOnLaunch") as? Bool ?? false
        self.logRetentionDays = UserDefaults.standard.object(forKey: "MacTidy.logRetentionDays") as? Int ?? 0
        self.aiConfig = Self.loadAIConfig()

        // Restore persisted state so relaunch isn't a blank screen + full rescan.
        self.recentTrashed = trashLog.load()
        self.cleanupHistory = cleanupLog.load()
        self.scanHistory = scanHistoryStore.load()
        // The one-time first-reclaim milestone: nil until the first real
        // cleanup that frees space, and only ever set once. Read from
        // UserDefaults so a relaunch mid-celebration still shows it.
        if let stored = UserDefaults.standard.object(forKey: "MacTidy.firstReclaimMilestone") as? Int64 {
            self.firstReclaimMilestone = stored
        }
        // Drop log entries older than the retention window before showing them.
        applyLogRetention()
        if let results = Self.loadLastScan(from: lastScanURL) {
            self.categoryResults = results
            self.scanStatus = "Last scan restored from previous session"
        }
    }

    func refreshFDA() {
        fdaGranted = FullDiskAccess.isGranted
    }

    func rescanCategories() async {
        // Coalesce duplicate triggers; cancel any in-flight scan first.
        scanTask?.cancel()
        isScanningCategories = true
        scanProgress = "Starting…"
        scanTotal = Category.allCases.count
        scanCompleted = 0
        let task = Task {
            let scanner = CategoryScanner()
            var completed = 0
            let results = await scanner.scanAll(
                progress: { category in
                    Task { @MainActor in self.scanProgress = "Scanning \(category.displayName)…" }
                },
                completed: { _ in
                    completed += 1
                    Task { @MainActor in self.scanCompleted = completed }
                }
            )
            if Task.isCancelled {
                await MainActor.run { isScanningCategories = false; scanProgress = ""; scanCompleted = 0 }
                return
            }
            await MainActor.run {
                categoryResults = results
                isScanningCategories = false
                scanProgress = ""
                scanCompleted = scanTotal
                scanStatus = "Last scan: \(Date.now.formatted(date: .omitted, time: .shortened))"
                persistLastScan(results)
                let snapshot = ScanSnapshot(
                    reclaimableBytes: results.reduce(0) { $0 + $1.totalBytes },
                    itemCount: results.reduce(0) { $0 + $1.items.count }
                )
                scanHistoryStore.append(snapshot)
                scanHistory = scanHistoryStore.load()
            }
        }
        scanTask = task
        await task.value
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: - Guided flow control

    /// Start the wizard: kick off a scan, then land on the dashboard where
    /// every category and tool is visible at once.
    func startFlow() async {
        flowSkipped.removeAll()
        flowPhase = .scanning
        await rescanCategories()
        // Scan apps and launch items in parallel so the dashboard's
        // Uninstaller / Startup tabs have data ready immediately.
        async let apps = scanUninstallCandidates()
        async let launch = Task.detached { LaunchItemsAuditor.audit() }.value
        flowApps = await apps
        flowLaunchItems = await launch
        rebuildFlowQueue()
        flowIndex = 0
        if flowQueue.isEmpty {
            flowPhase = .allClean
        } else {
            flowPhase = .dashboard
        }
    }

    /// Scans installed apps and their leftovers, keeping only non-Apple apps
    /// with meaningful size, for the uninstall action cards.
    private func scanUninstallCandidates() async -> [(app: InstalledApp, leftovers: [ScanItem])] {
        let apps = await AppUninstaller.installedApps()
        var result: [(InstalledApp, [ScanItem])] = []
        for app in apps where !app.isApple && app.sizeBytes > 50 * 1024 * 1024 {
            let leftovers = await AppUninstaller.leftovers(for: app)
            result.append((app, leftovers))
        }
        // Largest first.
        return result.sorted { $0.0.sizeBytes > $1.0.sizeBytes }
    }

    /// Rebuilds the ranked action queue from the current scan results plus
    /// uninstaller / launch-item / duplicate suggestions. Skipped items stay
    /// suppressed within a pass.
    func rebuildFlowQueue() {
        var queue: [FlowAction] = []

        // Cleanup recommendations from CoreKit's ranking engine — the core.
        let recs = Recommendations.ranked(from: categoryResults, limit: 100)
        for rec in recs where !flowSkipped.contains(rec.item.id.uuidString) {
            queue.append(.trash(
                items: [rec.item],
                title: rec.item.url.lastPathComponent,
                why: why(for: rec),
                icon: icon(for: rec)
            ))
        }

        // Uninstall suggestions: large non-Apple apps, folded in as actions.
        for (app, leftovers) in flowApps where !flowSkipped.contains("uninstall:" + app.id) {
            queue.append(.uninstall(app: app, leftovers: leftovers))
        }

        // Launch items that run at login but aren't loaded — stale candidates.
        let staleLaunch = flowLaunchItems.filter { $0.runAtLoad == true && !$0.isLoaded && $0.domain == .userAgent }
        if !staleLaunch.isEmpty {
            queue.append(.disableLaunch(items: staleLaunch))
        }

        // Rank by reclaimable bytes so the biggest wins lead. Non-byte actions
        // (disable, duplicates) sort toward the end naturally with 0 bytes.
        flowQueue = queue.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Applies the current trash action via the destructive gateway. In the
    /// dry pass, `dryRun` is on so nothing is actually trashed.
    @discardableResult
    func flowApplyTrash(_ items: [ScanItem]) -> DeletionOutcome {
        let plan = DeletionPlan(items: items)
        let outcome = execute(plan, kind: .deletion)
        flowLastOutcome = outcome
        return outcome
    }

    /// Switch from the dry pass to the real pass: turn dry-run off, clear
    /// skipped items, and return to the dashboard.
    func startRealPass() {
        dryRun = false
        flowPass = .real
        flowSkipped.removeAll()
        flowIndex = 0
        if flowQueue.isEmpty {
            flowPhase = .allClean
        } else {
            flowPhase = .dashboard
        }
    }

    /// Reset back to the welcome screen (e.g. after finishing).
    func resetFlow() {
        flowPhase = .welcome
        flowQueue = []
        flowIndex = 0
        flowSkipped.removeAll()
        flowLastOutcome = nil
    }

    private func why(for rec: Recommendation) -> String {
        switch rec.reason {
        case .safeCache:
            "A cache — the app rebuilds it on demand. Safe to trash; you'll get the space back immediately."
        case .staleInstaller:
            "An installer in Downloads older than 30 days. You almost certainly already installed it."
        case .staleBackup:
            "An old device backup. Make sure the device is backed up elsewhere before trashing."
        case .staleBuildDir:
            "Build artifacts of a project. Restore with a rebuild (npm install / cargo build)."
        case .bigFile:
            "A large file. Review it before trashing — large isn't necessarily junk."
        }
    }

    private func icon(for rec: Recommendation) -> String {
        switch rec.reason {
        case .safeCache: "internaldrive"
        case .staleInstaller: "shippingbox"
        case .staleBackup: "iphone"
        case .staleBuildDir: "hammer"
        case .bigFile: "doc"
        }
    }

    var totalReclaimable: Int64 {
        categoryResults.reduce(0) { $0 + $1.totalBytes }
    }

    var totalReclaimedHistorically: Int64 {
        cleanupHistory.reduce(0) { $0 + $1.reclaimedBytes }
    }

    /// The single gateway the UI uses for every deletion. Non-throwing: policy
    /// violations are reported per-item as skipped (see DeletionExecutor).
    @discardableResult
    func execute(
        _ plan: DeletionPlan,
        extraAllowedRoots: [URL] = [],
        kind: TrashRecord.Kind = .deletion
    ) -> DeletionOutcome {
        let executor = DeletionExecutor(
            policy: SafePathPolicy(extraAllowedRoots: extraAllowedRoots),
            dryRun: dryRun
        )
        let outcome = executor.execute(plan)
        recordOutcome(outcome, plan: plan, kind: kind)
        return outcome
    }

    /// Gateway for shell-based destructive actions (Docker, future brew). Like
    /// `execute`, it is non-throwing and per-item fail-closed: failures come
    /// back in the outcome's `failed` list. Unlike trashing, these actions are
    /// NOT Trash-undoable, so they are NOT recorded to `TrashLog` — only the
    /// reclaim-over-time `CleanupLog` gets an entry on real passes.
    @discardableResult
    func executeShellActions(
        _ actions: [any ShellAction],
        kind: CleanupEntry.Kind
    ) -> ShellActionOutcome {
        let outcome = ShellActionExecutor.execute(actions, dryRun: dryRun)
        if !outcome.dryRun, !outcome.succeeded.isEmpty {
            cleanupLog.append(CleanupEntry(
                kind: kind,
                reclaimedBytes: outcome.reclaimedBytes,
                itemCount: outcome.succeeded.count
            ))
            cleanupHistory = cleanupLog.load()
        }
        return outcome
    }

    /// Asks the configured AI advisor for a cleanup plan matching a
    /// natural-language intent. Returns the advisor's reasoning + a
    /// `DeletionPlan` built from real `ScanItem`s in the current scan. Falls
    /// back to the deterministic `Recommendations` ranking when no provider is
    /// configured, the key is missing, or the call fails/times out — so the
    /// app works identically without AI. Never throws.
    func aiPlan(for intent: String) async -> (plan: DeletionPlan, reasoning: String) {
        // Deterministic fallback when AI is off or unavailable.
        guard let advisor = advisor else {
            let items = Recommendations.ranked(from: categoryResults, limit: 100).map(\.item)
            return (DeletionPlan(items: items),
                    "No AI provider configured — showing the ranked safe cleanup.")
        }
        isAIThinking = true
        defer { isAIThinking = false }
        do {
            let advice = try await advisor.plan(
                for: intent, categories: categoryResults, config: aiConfig
            )
            lastAIReasoning = advice.reasoning
            return (DeletionPlan(items: advice.items), advice.reasoning)
        } catch {
            // Fall back to deterministic ranking on any failure/timeout.
            let items = Recommendations.ranked(from: categoryResults, limit: 100).map(\.item)
            let reason = "AI request failed (\(error.localizedDescription)) — showing the ranked safe cleanup."
            return (DeletionPlan(items: items), reason)
        }
    }

    /// Asks the advisor to explain a single item. Returns a short string on
    /// failure so the UI always has something to show.
    func explain(item: ScanItem) async -> ItemExplanation {
        guard let advisor = advisor else {
            return ItemExplanation(summary: "No AI provider configured.")
        }
        do {
            return try await advisor.explain(item, config: aiConfig)
        } catch {
            return ItemExplanation(summary: "Couldn't get an explanation: \(error.localizedDescription)")
        }
    }

    /// Builds a system snapshot and asks the advisor for proactive insights.
    /// Falls back to deterministic, locally-generated insights when no provider
    /// is configured or the call fails — so the Insights panel is useful even
    /// without AI. Never throws.
    func generateInsights() async -> [Insight] {
        let processes = ProcessScanner.scan()
        let memory = ProcessScanner.memorySummary()
        let snapshot = SystemSnapshot(
            categories: categoryResults, memory: memory, processes: processes
        )
        if let advisor = advisor {
            do {
                let result = try await advisor.insights(for: snapshot, config: aiConfig)
                if !result.isEmpty { return result }
            } catch {
                // Fall through to deterministic insights on failure.
            }
        }
        return DeterministicInsights.from(snapshot)
    }

    /// Gateway for clone-based dedup — same policy and dry-run rules as
    /// deletion, but content-preserving (copies become APFS clones).
    @discardableResult
    func deduplicate(
        _ set: DuplicateSet,
        extraAllowedRoots: [URL] = []
    ) -> CloneDeduplicator.Outcome {
        let outcome = CloneDeduplicator.deduplicate(
            set,
            policy: SafePathPolicy(extraAllowedRoots: extraAllowedRoots),
            dryRun: dryRun
        )
        recordDedupOutcome(outcome, set: set)
        return outcome
    }

    /// Restores a previously trashed item to its original location and removes
    /// it from the log.
    @discardableResult
    func restore(_ record: TrashRecord) throws -> URL {
        let destination = try Restorer.restore(record)
        trashLog.remove(record.id)
        recentTrashed = trashLog.load()
        return destination
    }

    // MARK: - Memory maintenance

    /// The most recent disk-cache purge outcome, surfaced inline on the
    /// Memory card. Nil until the user runs one this session.
    var lastPurgeResult: MemoryMaintenance.PurgeResult?

    /// Runs `purge` (disk cache) via an admin prompt — the only memory action
    /// beyond quitting idle apps. Non-throwing; result lands in
    /// `lastPurgeResult` for the UI.
    @discardableResult
    func purgeDiskCache() -> MemoryMaintenance.PurgeResult {
        let result = MemoryMaintenance.purgeDiskCache()
        lastPurgeResult = result
        return result
    }

    /// Dismisses a record from the Recently Trashed list without restoring
    /// (the item stays in the Trash).
    func dismissTrashed(_ record: TrashRecord) {
        trashLog.remove(record.id)
        recentTrashed = trashLog.load()
    }

    /// Clears the post-cleanup Undo toast.
    func clearUndoToast() {
        lastUndoableOutcome = nil
    }

    func refreshLogs() {
        recentTrashed = trashLog.load()
        cleanupHistory = cleanupLog.load()
    }

    // MARK: - Recording

    /// Maps a `TrashRecord.Kind` to the bucketed `CleanupEntry.Kind` for the
    /// reclaim-over-time log.
    private func cleanupKind(for kind: TrashRecord.Kind) -> CleanupEntry.Kind {
        switch kind {
        case .deletion: .deletion
        case .dedup: .dedup
        case .uninstall: .uninstall
        }
    }

    private func recordOutcome(
        _ outcome: DeletionOutcome, plan: DeletionPlan,
        kind: TrashRecord.Kind
    ) {
        guard !outcome.dryRun, !outcome.trashed.isEmpty else { return }
        // Build persisted trash records carrying per-item sizes from the plan.
        let sizeByPath = Dictionary(plan.candidates.map { ($0.url.path, $0.sizeBytes) },
                                    uniquingKeysWith: { a, _ in a })
        let records = outcome.trashed.compactMap { record -> TrashRecord? in
            guard record.trashLocation != nil else { return nil }
            return TrashRecord(
                original: record.original,
                trashLocation: record.trashLocation,
                date: Date(),
                bytes: sizeByPath[record.original.path] ?? 0,
                kind: kind
            )
        }
        trashLog.append(records)
        recentTrashed = trashLog.load()
        cleanupLog.append(CleanupEntry(
            kind: cleanupKind(for: kind),
            reclaimedBytes: outcome.reclaimedBytes,
            itemCount: outcome.trashed.count
        ))
        cleanupHistory = cleanupLog.load()
        lastUndoableOutcome = (records, "Moved \(outcome.trashed.count) item\(outcome.trashed.count == 1 ? "" : "s") (\(outcome.reclaimedBytes.formattedBytes)) to Trash")
        // One-time first-reclaim celebration: fire only on the user's first
        // real cleanup that actually frees space. Persisted so it never fires
        // again (a future relaunch sees the stored value and skips).
        if firstReclaimMilestone == nil, outcome.reclaimedBytes > 0 {
            firstReclaimMilestone = outcome.reclaimedBytes
            UserDefaults.standard.set(outcome.reclaimedBytes, forKey: "MacTidy.firstReclaimMilestone")
        }
    }

    private func recordDedupOutcome(
        _ outcome: CloneDeduplicator.Outcome, set: DuplicateSet
    ) {
        guard !outcome.dryRun, !outcome.deduplicated.isEmpty else { return }
        let records = outcome.deduplicated.compactMap { record -> TrashRecord? in
            guard record.trashLocation != nil else { return nil }
            return TrashRecord(
                original: record.original,
                trashLocation: record.trashLocation,
                date: Date(),
                bytes: set.fileSizeBytes,
                kind: .dedup
            )
        }
        trashLog.append(records)
        recentTrashed = trashLog.load()
        cleanupLog.append(CleanupEntry(
            kind: .dedup,
            reclaimedBytes: outcome.reclaimedBytes,
            itemCount: outcome.deduplicated.count
        ))
        cleanupHistory = cleanupLog.load()
        lastUndoableOutcome = (records, "Deduplicated \(outcome.deduplicated.count) cop\(outcome.deduplicated.count == 1 ? "y" : "ies") (\(outcome.reclaimedBytes.formattedBytes))")
    }

    // MARK: - Scan persistence

    private func persistLastScan(_ results: [CategoryResult]) {
        guard let data = try? JSONEncoder().encode(results) else { return }
        try? data.write(to: lastScanURL, options: .atomic)
    }

    private static func loadLastScan(from url: URL) -> [CategoryResult]? {
        guard let data = try? Data(contentsOf: url),
              let results = try? JSONDecoder().decode([CategoryResult].self, from: data)
        else { return nil }
        return results
    }

    // MARK: - Settings persistence

    private static let extraRootsKey = "MacTidy.extraAllowedRoots"

    private func persistExtraAllowedRoots() {
        let paths = extraAllowedRoots.map(\.path)
        UserDefaults.standard.set(paths, forKey: Self.extraRootsKey)
    }

    private static func loadExtraAllowedRoots() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: extraRootsKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - AI config persistence

    private static let aiConfigKey = "MacTidy.aiConfig"
    private func persistAIConfig() {
        if let data = try? JSONEncoder().encode(aiConfig) {
            UserDefaults.standard.set(data, forKey: Self.aiConfigKey)
        }
    }
    private static func loadAIConfig() -> AIConfig {
        guard let data = UserDefaults.standard.data(forKey: aiConfigKey),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data) else {
            return AIConfig()
        }
        return config
    }

    /// Resolves the current `aiConfig` to a concrete advisor, or nil when no
    /// provider is configured / key missing — callers fall back to the
    /// deterministic `Recommendations` ranking.
    var advisor: CleanAdvisor? { CleanAdvisorFactory.make(config: aiConfig) }

    /// Applies the current retention window to both logs and refreshes the
    /// in-memory copies. Safe to call with `logRetentionDays == 0` (no-op).
    func applyLogRetention() {
        trashLog.pruneOlderThan(days: logRetentionDays)
        cleanupLog.pruneOlderThan(days: logRetentionDays)
        recentTrashed = trashLog.load()
        cleanupHistory = cleanupLog.load()
    }

    /// Adds a root to the allow-list (deduped, symlink-resolved). No-op if the
    /// picker was cancelled.
    func addExtraAllowedRoot(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        guard !extraAllowedRoots.contains(where: { $0 == resolved }) else { return }
        extraAllowedRoots.append(resolved)
    }

    func removeExtraAllowedRoot(_ url: URL) {
        extraAllowedRoots.removeAll { $0 == url.resolvingSymlinksInPath() }
    }
}
import Foundation
import Observation
import CoreKit

@MainActor
@Observable
final class AppState {
    var fdaGranted = FullDiskAccess.isGranted

    /// Dry-run is the app-wide default; every confirmation sheet shows the
    /// toggle. Persisted so it survives relaunches.
    var dryRun: Bool {
        didSet { UserDefaults.standard.set(dryRun, forKey: "MacTidy.dryRun") }
    }

    var categoryResults: [CategoryResult] = []
    var isScanningCategories = false
    var scanStatus: String = ""
    /// Human-readable progress for the current category scan ("Scanning User caches…").
    var scanProgress: String = ""

    /// Everything MacTidy has trashed, newest first. Drives the "Recently
    /// Trashed" view and the post-cleanup Undo toast.
    var recentTrashed: [TrashRecord] = []
    /// The most recent real (non-dry-run) outcome, for the Undo toast.
    var lastUndoableOutcome: (records: [TrashRecord], label: String)?

    /// Completed cleanups, newest first — the honest reclaim-over-time log.
    var cleanupHistory: [CleanupEntry] = []

    /// The scan task, kept so the UI can cancel an in-flight scan.
    private var scanTask: Task<Void, Never>?

    private let trashLog: TrashLog
    private let cleanupLog: CleanupLog
    private let lastScanURL: URL

    init(
        trashLog: TrashLog = .shared,
        cleanupLog: CleanupLog = .shared
    ) {
        self.trashLog = trashLog
        self.cleanupLog = cleanupLog
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacTidy")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.lastScanURL = support.appending(path: "last-scan.json")
        self.dryRun = UserDefaults.standard.object(forKey: "MacTidy.dryRun") as? Bool ?? true

        // Restore persisted state so relaunch isn't a blank screen + full rescan.
        self.recentTrashed = trashLog.load()
        self.cleanupHistory = cleanupLog.load()
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
        let task = Task {
            let scanner = CategoryScanner()
            let results = await scanner.scanAll { category in
                Task { @MainActor in self.scanProgress = "Scanning \(category.displayName)…" }
            }
            if Task.isCancelled {
                await MainActor.run { isScanningCategories = false; scanProgress = "" }
                return
            }
            await MainActor.run {
                categoryResults = results
                isScanningCategories = false
                scanProgress = ""
                scanStatus = "Last scan: \(Date.now.formatted(date: .omitted, time: .shortened))"
                persistLastScan(results)
            }
        }
        scanTask = task
        await task.value
    }

    func cancelScan() {
        scanTask?.cancel()
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
        // Deletion and uninstall both flow through here as `.deletion`; the
        // uninstaller doesn't pass a distinct kind, and bucketing them
        // together is fine for the reclaim-over-time total.
        cleanupLog.append(CleanupEntry(
            kind: kind == .dedup ? .dedup : .deletion,
            reclaimedBytes: outcome.reclaimedBytes,
            itemCount: outcome.trashed.count
        ))
        cleanupHistory = cleanupLog.load()
        lastUndoableOutcome = (records, "Moved \(outcome.trashed.count) item\(outcome.trashed.count == 1 ? "" : "s") (\(outcome.reclaimedBytes.formattedBytes)) to Trash")
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
}
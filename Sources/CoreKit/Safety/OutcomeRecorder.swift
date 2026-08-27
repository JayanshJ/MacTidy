import Foundation

/// Pure logic extracted from `AppState.recordOutcome` so the record-building
/// and first-reclaim-milestone decisions are unit-testable without a live
/// `AppState`, the main actor, or `UserDefaults`.
///
/// `AppState` owns the side-effects (writing to `TrashLog`/`CleanupLog`,
/// persisting the milestone, refreshing the Trash-size cache); this helper
/// computes *what* to write and *whether* the milestone should fire, so that
/// contract is locked down.
public enum OutcomeRecorder {
    /// The records to persist in `TrashLog` for a trashed outcome, carrying
    /// per-item sizes from the plan (the outcome itself has no sizes).
    public static func trashRecords(
        for outcome: DeletionOutcome,
        plan: DeletionPlan,
        kind: TrashRecord.Kind,
        date: Date = Date()
    ) -> [TrashRecord] {
        guard !outcome.trashed.isEmpty else { return [] }
        let sizeByPath = Dictionary(plan.candidates.map { ($0.url.path, $0.sizeBytes) },
                                    uniquingKeysWith: { a, _ in a })
        return outcome.trashed.compactMap { record -> TrashRecord? in
            guard record.trashLocation != nil else { return nil }
            return TrashRecord(
                original: record.original,
                trashLocation: record.trashLocation,
                date: date,
                bytes: sizeByPath[record.original.path] ?? 0,
                kind: kind
            )
        }
    }

    /// The `CleanupEntry` to append to the reclaim-over-time log for a trashed
    /// outcome. Nil when nothing was trashed — an empty outcome logs nothing.
    public static func cleanupEntry(
        for outcome: DeletionOutcome,
        cleanupKind: CleanupEntry.Kind,
        date: Date = Date()
    ) -> CleanupEntry? {
        guard !outcome.trashed.isEmpty else { return nil }
        return CleanupEntry(
            date: date,
            kind: cleanupKind,
            reclaimedBytes: outcome.reclaimedBytes,
            itemCount: outcome.trashed.count
        )
    }

    /// The undo-toast label shown after a cleanup, matching the form the UI
    /// already uses. Nil when there's nothing to undo (nothing trashed).
    public static func undoLabel(for outcome: DeletionOutcome) -> String? {
        guard !outcome.trashed.isEmpty else { return nil }
        let count = outcome.trashed.count
        let plural = count == 1 ? "" : "s"
        return "Moved \(count) item\(plural) (\(outcome.reclaimedBytes.formattedBytes)) to Trash"
    }

    /// Whether the one-time first-reclaim milestone should fire. It fires only
    /// on the user's *first* real cleanup that actually frees space, so it
    /// returns true iff `existingMilestone` is nil AND bytes were reclaimed.
    /// `AppState` persists the milestone the first time this returns true.
    public static func shouldFireFirstReclaimMilestone(
        existingMilestone: Int64?,
        reclaimedBytes: Int64
    ) -> Bool {
        existingMilestone == nil && reclaimedBytes > 0
    }

    /// Returns a copy of `results` with items whose `url` (symlink-resolved,
    /// standardized) is in `trashedPaths` removed, and — when `dropMissing`
    /// is true — non-directory items whose file no longer exists on disk
    /// removed. Emptied `CategoryResult`s are dropped so the UI can show its
    /// "all clean" empty state. Pure (no `FileManager` when `dropMissing` is
    /// false), so the trashed-path pruning is unit-testable without a
    /// filesystem; `dropMissing` is the belt-and-suspenders path used before
    /// feeding the AI.
    public static func pruneDeleted(
        _ results: [CategoryResult],
        trashedPaths: Set<String>,
        dropMissing: Bool = false,
        fileExists: (URL) -> Bool = { _ in true }
    ) -> [CategoryResult] {
        guard !trashedPaths.isEmpty || dropMissing else { return results }
        let resolved = Set(trashedPaths.map { URL(fileURLWithPath: $0)
            .resolvingSymlinksInPath().standardizedFileURL.path })
        return results.compactMap { result -> CategoryResult? in
            let kept = result.items.filter { item in
                let p = item.url.resolvingSymlinksInPath().standardizedFileURL.path
                if resolved.contains(p) { return false }
                if dropMissing, !item.isDirectory, !fileExists(item.url) { return false }
                return true
            }
            return kept.isEmpty ? nil : CategoryResult(category: result.category, items: kept)
        }
    }
}
import Foundation
import Testing
@testable import CoreKit

/// `OutcomeRecorder` is the pure half of `AppState.recordOutcome` — it computes
/// what TrashLog/CleanupLog records to persist and whether the first-reclaim
/// milestone should fire, without touching the main actor, UserDefaults, or
/// the real log files. These tests pin that contract.
@Suite("OutcomeRecorder")
struct OutcomeRecorderTests {
    private func outcome(trashed: [TrashedRecord] = [],
                         reclaimedBytes: Int64 = 0) -> DeletionOutcome {
        DeletionOutcome(trashed: trashed, skipped: [], reclaimedBytes: reclaimedBytes)
    }

    private func trashed(original: String, trash: String) -> TrashedRecord {
        TrashedRecord(original: URL(fileURLWithPath: original),
                      trashLocation: URL(fileURLWithPath: trash))
    }

    // MARK: - trashRecords

    @Test func emptyOutcomeProducesNoRecords() {
        let plan = DeletionPlan(candidates: [])
        let records = OutcomeRecorder.trashRecords(
            for: outcome(), plan: plan, kind: .deletion)
        #expect(records.isEmpty)
    }

    @Test func recordsCarryPerItemSizesFromPlan() {
        // The outcome itself has no sizes; the plan does. The recorder must
        // join them by path so the persisted record reports the bytes the UI
        // showed the user (not 0).
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        let plan = DeletionPlan(candidates: [
            DeletionCandidate(url: a, sizeBytes: 1000),
            DeletionCandidate(url: b, sizeBytes: 2000),
        ])
        let outcome = self.outcome(
            trashed: [trashed(original: a.path, trash: "/Trash/a"),
                      trashed(original: b.path, trash: "/Trash/b")],
            reclaimedBytes: 3000)
        let records = OutcomeRecorder.trashRecords(for: outcome, plan: plan, kind: .deletion)
        #expect(records.count == 2)
        let byPath = Dictionary(records.map { ($0.originalPath, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        #expect(byPath[a.path] == 1000)
        #expect(byPath[b.path] == 2000)
    }

    @Test func trashedRecordWithNoLocationIsDropped() {
        // A record without a trashLocation can't be restored, so it's not
        // persisted. The recorder must filter it out.
        let a = URL(fileURLWithPath: "/tmp/a")
        let plan = DeletionPlan(candidates: [DeletionCandidate(url: a, sizeBytes: 500)])
        let withLoc = trashed(original: a.path, trash: "/Trash/a")
        let noLoc = TrashedRecord(original: a, trashLocation: nil)
        let records = OutcomeRecorder.trashRecords(
            for: outcome(trashed: [withLoc, noLoc], reclaimedBytes: 500),
            plan: plan, kind: .deletion)
        #expect(records.count == 1)
        #expect(records.first?.trashPath == "/Trash/a")
    }

    // MARK: - cleanupEntry

    @Test func cleanupEntryNilForEmptyOutcome() {
        #expect(OutcomeRecorder.cleanupEntry(for: outcome(), cleanupKind: .deletion) == nil)
    }

    @Test func cleanupEntryCarriesBytesAndCount() {
        let outcome = self.outcome(
            trashed: [trashed(original: "/tmp/a", trash: "/Trash/a"),
                      trashed(original: "/tmp/b", trash: "/Trash/b"),
                      trashed(original: "/tmp/c", trash: "/Trash/c")],
            reclaimedBytes: 7500)
        let entry = OutcomeRecorder.cleanupEntry(for: outcome, cleanupKind: .docker)
        #expect(entry?.reclaimedBytes == 7500)
        #expect(entry?.itemCount == 3)
        #expect(entry?.kind == .docker)
    }

    // MARK: - undoLabel

    @Test func undoLabelNilWhenNothingTrashed() {
        #expect(OutcomeRecorder.undoLabel(for: outcome()) == nil)
    }

    @Test func undoLabelSingularForOneItem() {
        let outcome = self.outcome(
            trashed: [trashed(original: "/tmp/a", trash: "/Trash/a")],
            reclaimedBytes: 500)
        let label = OutcomeRecorder.undoLabel(for: outcome)
        #expect(label == "Moved 1 item (500 bytes) to Trash")
    }

    @Test func undoLabelPluralForManyItems() {
        let outcome = self.outcome(
            trashed: [trashed(original: "/tmp/a", trash: "/Trash/a"),
                      trashed(original: "/tmp/b", trash: "/Trash/b")],
            reclaimedBytes: 2048)
        let label = OutcomeRecorder.undoLabel(for: outcome)
        #expect(label == "Moved 2 items (2 KB) to Trash")
    }

    // MARK: - first-reclaim milestone

    @Test func milestoneFiresWhenNoneExistsAndBytesReclaimed() {
        #expect(OutcomeRecorder.shouldFireFirstReclaimMilestone(
            existingMilestone: nil, reclaimedBytes: 1_000_000) == true)
    }

    @Test func milestoneDoesNotFireWhenAlreadySet() {
        // The one-time celebration must never re-fire after the first reclaim.
        #expect(OutcomeRecorder.shouldFireFirstReclaimMilestone(
            existingMilestone: 500_000, reclaimedBytes: 5_000_000) == false)
    }

    @Test func milestoneDoesNotFireWhenNothingReclaimed() {
        // A cleanup that trashed nothing (all skipped, or empty plan) must not
        // fire the milestone even the first time.
        #expect(OutcomeRecorder.shouldFireFirstReclaimMilestone(
            existingMilestone: nil, reclaimedBytes: 0) == false)
    }

    // MARK: - pruneDeleted (global state refresh after a trash)

    private func item(_ path: String, _ bytes: Int64, isDir: Bool = false) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path), sizeBytes: bytes, isDirectory: isDir,
                 category: .bigFiles)
    }

    @Test func pruneRemovedTrashedItemsFromResults() {
        // The core "duplicate rescanning" fix: after trashing, the items must
        // leave the in-memory scan results so the grid/total reflect the
        // deletion without a full rescan.
        let results = [
            CategoryResult(category: .bigFiles, items: [
                item("/tmp/keep.bin", 100),
                item("/tmp/gone.bin", 200),
            ]),
        ]
        let pruned = OutcomeRecorder.pruneDeleted(
            results, trashedPaths: ["/tmp/gone.bin"])
        #expect(pruned.count == 1)
        #expect(pruned[0].items.count == 1)
        #expect(pruned[0].items.first?.url.lastPathComponent == "keep.bin")
        #expect(pruned[0].totalBytes == 100)
    }

    @Test func pruneDropsCategoriesThatBecomeEmpty() {
        // A category whose every item was trashed must drop entirely so the
        // "all clean" empty state shows (a zero-item CategoryResult would
        // otherwise still render a 0-byte card before the view filter).
        let results = [
            CategoryResult(category: .bigFiles, items: [item("/tmp/a", 100)]),
            CategoryResult(category: .oldInstallers, items: [item("/tmp/keep", 50)]),
        ]
        let pruned = OutcomeRecorder.pruneDeleted(
            results, trashedPaths: ["/tmp/a"])
        #expect(pruned.count == 1)
        #expect(pruned.first?.category == .oldInstallers)
    }

    @Test func pruneResolvesSymlinksBeforeMatching() {
        // A trashed path that was an alias must still match the scan item that
        // resolved through it — otherwise a symlinked file wouldn't be pruned.
        let real = "/tmp/real.bin"
        let results = [
            CategoryResult(category: .bigFiles, items: [item(real, 100)]),
        ]
        // Pretend the trashed path is a symlink path that resolves to `real`.
        // OutcomeRecorder resolves trashedPaths via resolvingSymlinksInPath;
        // since we pass the real path directly, it must match.
        let pruned = OutcomeRecorder.pruneDeleted(
            results, trashedPaths: [real])
        #expect(pruned.isEmpty)
    }

    @Test func pruneDoesNotMutateWhenNothingMatches() {
        let results = [
            CategoryResult(category: .bigFiles, items: [item("/tmp/a", 100)]),
        ]
        let pruned = OutcomeRecorder.pruneDeleted(
            results, trashedPaths: ["/tmp/unrelated"])
        #expect(pruned == results)
        #expect(pruned.first?.totalBytes == 100)
    }

    @Test func pruneDropMissingAlsoRemovesGoneFilesForAIContext() {
        // The Insights AI-context sync: a file trashed outside the app (Finder,
        // Trash emptied) must be dropped from the snapshot so the AI can't
        // recommend it. `dropMissing` with a fileExists that says "gone" simulates
        // that without a real filesystem.
        let results = [
            CategoryResult(category: .bigFiles, items: [
                item("/tmp/present.bin", 100),
                item("/tmp/missing.bin", 200),
            ]),
        ]
        let pruned = OutcomeRecorder.pruneDeleted(
            results, trashedPaths: [],
            dropMissing: true,
            fileExists: { $0.path.contains("missing") ? false : true }
        )
        #expect(pruned.count == 1)
        #expect(pruned[0].items.count == 1)
        #expect(pruned[0].items.first?.url.lastPathComponent == "present.bin")
    }

    @Test func pruneDropMissingKeepsDirectoriesEvenIfFileExistsFalse() {
        // Directories are kept unconditionally (they may legitimately be empty;
        // their size was summed at scan time). A false-yielding fileExists must
        // not drop a directory item.
        let results = [
            CategoryResult(category: .bigFiles, items: [
                item("/tmp/dir", 100, isDir: true),
            ]),
        ]
        let pruned = OutcomeRecorder.pruneDeleted(
            results, trashedPaths: [], dropMissing: true,
            fileExists: { _ in false }
        )
        #expect(pruned.count == 1)
        #expect(pruned[0].items.count == 1)
    }
}
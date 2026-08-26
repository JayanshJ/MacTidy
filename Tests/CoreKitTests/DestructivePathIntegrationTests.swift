import Foundation
import Testing
@testable import CoreKit

/// Integration test for the single destructive path as `AppState` runs it:
/// `DeletionExecutor` (real `Trasher` → `FileManager.trashItem`) →
/// `OutcomeRecorder` → real `TrashLog` + `CleanupLog` (injected temp storage).
///
/// `AppState` itself can't be imported here (it's an executable target), so
/// this mirrors its `execute` + `recordOutcome` sequence against CoreKit
/// pieces — that's the actual contract: the same pipeline, the same logs,
/// the same milestone decision. Everything uses real `trashItem` and real
/// JSON log files, just pointed at temp paths.
@Suite("Destructive path integration")
struct DestructivePathIntegrationTests {
    private func makeFixture() throws -> (URL, SafePathPolicy, DeletionPlan) {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appending(path: "mactidy-integ-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let a = sandbox.appending(path: "a.txt")
        let b = sandbox.appending(path: "b.txt")
        try Data("aaaa".utf8).write(to: a)
        try Data("bb".utf8).write(to: b)
        let plan = DeletionPlan(candidates: [
            DeletionCandidate(url: a, sizeBytes: 4),
            DeletionCandidate(url: b, sizeBytes: 2),
        ])
        return (sandbox, SafePathPolicy(extraAllowedRoots: [sandbox]), plan)
    }

    /// The full `AppState.execute` + `recordOutcome` sequence, minus the
    /// main-actor/UserDefaults wrapper: execute, build records via
    /// `OutcomeRecorder`, append to real `TrashLog` + `CleanupLog`, decide
    /// the milestone. Asserts the logs actually get written and the
    /// milestone fires exactly once.
    @Test func executeRecordsToTrashAndCleanupLogsAndFiresMilestone() throws {
        let (sandbox, policy, plan) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Real logs pointed at temp storage — not ~/Library/Application Support.
        let support = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-integ-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let trashLog = TrashLog(storageURL: support.appending(path: "trash-log.json"))
        let cleanupLog = CleanupLog(storageURL: support.appending(path: "cleanup-log.json"))

        // 1. Execute — the real destructive path (trashItem, per-item fail-closed).
        let outcome = DeletionExecutor(policy: policy).execute(plan)
        #expect(outcome.trashed.count == 2)
        #expect(outcome.skipped.isEmpty)
        #expect(outcome.reclaimedBytes == 6)
        defer {  // clean trashed files out of the Trash so tests don't litter
            for record in outcome.trashed {
                if let inTrash = record.trashLocation { try? FileManager.default.removeItem(at: inTrash) }
            }
        }

        // 2. recordOutcome: build the persisted records + cleanup entry.
        let records = OutcomeRecorder.trashRecords(for: outcome, plan: plan, kind: .deletion)
        trashLog.append(records)
        let entry = OutcomeRecorder.cleanupEntry(for: outcome, cleanupKind: .deletion)
        #expect(entry != nil)
        if let entry { cleanupLog.append(entry) }

        // 3. The logs really persisted (round-trip through disk).
        let loadedTrash = trashLog.load()
        #expect(loadedTrash.count == 2)
        #expect(Set(loadedTrash.map { $0.originalPath }) == Set(plan.candidates.map { $0.url.path }))
        let loadedCleanup = cleanupLog.load()
        #expect(loadedCleanup.count == 1)
        #expect(loadedCleanup.first?.reclaimedBytes == 6)
        #expect(loadedCleanup.first?.itemCount == 2)
        #expect(loadedCleanup.first?.kind == .deletion)

        // 4. First-reclaim milestone fires once on the first reclaim, then never again.
        let milestone1 = OutcomeRecorder.shouldFireFirstReclaimMilestone(
            existingMilestone: nil, reclaimedBytes: outcome.reclaimedBytes)
        #expect(milestone1 == true)
        // Simulate AppState persisting it; a second run must not re-fire.
        let milestone2 = OutcomeRecorder.shouldFireFirstReclaimMilestone(
            existingMilestone: outcome.reclaimedBytes, reclaimedBytes: 1_000_000)
        #expect(milestone2 == false)
    }

    /// A plan where every candidate is policy-rejected (e.g. all system paths)
    /// trashes nothing, logs no TrashLog records, writes no CleanupLog entry,
    /// and never fires the milestone — mirroring `recordOutcome`'s empty guard.
    @Test func rejectedPlanLogsAndTrashesNothing() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-integ-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let support = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-integ-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let trashLog = TrashLog(storageURL: support.appending(path: "trash-log.json"))
        let cleanupLog = CleanupLog(storageURL: support.appending(path: "cleanup-log.json"))

        // Plan of all-rejected paths — nothing inside the sandbox's allowed root.
        let plan = DeletionPlan(candidates: [
            DeletionCandidate(url: URL(fileURLWithPath: "/System/Library"), sizeBytes: 0),
        ])
        let outcome = DeletionExecutor(policy: SafePathPolicy()).execute(plan)
        #expect(outcome.trashed.isEmpty)
        #expect(outcome.skipped.count == 1)

        // recordOutcome's empty guard: nothing to write, nothing to celebrate.
        let records = OutcomeRecorder.trashRecords(for: outcome, plan: plan, kind: .deletion)
        #expect(records.isEmpty)
        trashLog.append(records)
        #expect(cleanupLog.load().isEmpty)
        #expect(OutcomeRecorder.cleanupEntry(for: outcome, cleanupKind: .deletion) == nil)
        #expect(OutcomeRecorder.undoLabel(for: outcome) == nil)
        #expect(OutcomeRecorder.shouldFireFirstReclaimMilestone(
            existingMilestone: nil, reclaimedBytes: outcome.reclaimedBytes) == false)
    }
}
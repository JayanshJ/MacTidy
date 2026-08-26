import Foundation
import Testing
@testable import CoreKit

@Suite("DeletionExecutor")
struct DeletionPlanTests {
    /// Creates an isolated sandbox dir with two small files and returns
    /// (sandbox, policy scoped to it, plan covering the files).
    func makeFixture() throws -> (URL, SafePathPolicy, DeletionPlan) {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appending(path: "mactidy-test-\(UUID().uuidString)")
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

    @Test func policyViolationIsSkippedNotFatal() throws {
        let (sandbox, policy, plan) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var poisoned = plan
        poisoned.candidates.append(
            DeletionCandidate(url: URL(fileURLWithPath: "/System/Library"), sizeBytes: 0))

        // Partial execution: the bad path is skipped (with a policy reason),
        // but the valid candidates still go through. Fail-closed per item,
        // not abort-all.
        let outcome = DeletionExecutor(policy: policy).execute(poisoned)
        #expect(outcome.trashed.count == 2)
        #expect(outcome.skipped.count == 1)
        #expect(outcome.skipped.first?.reason.contains("system path") ?? false)
        // The valid files really were trashed…
        for candidate in plan.candidates {
            #expect(!FileManager.default.fileExists(atPath: candidate.url.path))
        }
        // …and the rejected one was not.
        #expect(FileManager.default.fileExists(atPath: "/System/Library"))
        for record in outcome.trashed {
            if let inTrash = record.trashLocation { try? FileManager.default.removeItem(at: inTrash) }
        }
    }

    @Test func realRunMovesToTrash() throws {
        let (sandbox, policy, plan) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let outcome = DeletionExecutor(policy: policy).execute(plan)

        #expect(outcome.skipped.isEmpty)
        #expect(outcome.trashed.count == 2)
        for record in outcome.trashed {
            #expect(!FileManager.default.fileExists(atPath: record.original.path))
            let inTrash = try #require(record.trashLocation)
            #expect(FileManager.default.fileExists(atPath: inTrash.path))
            // Clean up the trashed copies so tests don't litter the Trash.
            try? FileManager.default.removeItem(at: inTrash)
        }
    }

    @Test func missingFileIsSkippedNotFatal() throws {
        let (sandbox, policy, plan) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var withGhost = plan
        withGhost.candidates.append(
            DeletionCandidate(url: sandbox.appending(path: "never-existed.txt"), sizeBytes: 100))

        let outcome = DeletionExecutor(policy: policy).execute(withGhost)
        #expect(outcome.trashed.count == 2)
        #expect(outcome.skipped.count == 1)
        #expect(outcome.reclaimedBytes == 6)
        for record in outcome.trashed {
            if let inTrash = record.trashLocation { try? FileManager.default.removeItem(at: inTrash) }
        }
    }
}

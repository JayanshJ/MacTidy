import Darwin
import Foundation
import Testing
@testable import CoreKit

@Suite("Clone-aware dedup")
struct CloneDedupTests {
    /// Sandbox with: a.bin (original), b.bin (independent identical copy,
    /// wastes space), c.bin (APFS clone of a.bin, wastes nothing).
    func makeFixture() throws -> (sandbox: URL, payload: Data) {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appending(path: "mactidy-dedup-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let payload = Data((0..<32_768).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: sandbox.appending(path: "a.bin"))
        try payload.write(to: sandbox.appending(path: "b.bin")) // real second copy
        guard clonefile(sandbox.appending(path: "a.bin").path,
                        sandbox.appending(path: "c.bin").path, 0) == 0 else {
            throw CocoaError(.fileWriteUnknown) // tmp not APFS? should not happen
        }
        return (sandbox, payload)
    }

    @Test func clonesAreRecognizedAsSharedStorage() async throws {
        let (sandbox, payload) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sets = await DuplicateFinder.find(in: [sandbox])
        #expect(sets.count == 1)
        let set = try #require(sets.first)

        #expect(set.files.count == 3)
        // a+c share storage (clone); b is an independent second copy.
        #expect(set.physicalGroups.count == 2)
        #expect(set.alreadySharedCount == 1)
        // Only b's copy is honestly reclaimable — not size × 2.
        #expect(set.wastedBytes == Int64(payload.count))
    }

    @Test func dryRunDeduplicationTouchesNothing() async throws {
        let (sandbox, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let before = await DuplicateFinder.find(in: [sandbox])
        let set = try #require(before.first)
        let policy = SafePathPolicy(extraAllowedRoots: [sandbox])

        let outcome = CloneDeduplicator.deduplicate(set, policy: policy, dryRun: true)

        #expect(outcome.dryRun)
        #expect(outcome.deduplicated.count == 1)
        #expect(outcome.deduplicated.allSatisfy { $0.trashLocation == nil })
        let after = await DuplicateFinder.find(in: [sandbox])
        #expect(after.first?.physicalGroups.count == 2, "dry run must not dedup")
    }

    @Test func deduplicationReclaimsSpaceAndPreservesContent() async throws {
        let (sandbox, payload) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let before = await DuplicateFinder.find(in: [sandbox])
        let set = try #require(before.first)
        let policy = SafePathPolicy(extraAllowedRoots: [sandbox])

        let outcome = CloneDeduplicator.deduplicate(set, policy: policy, dryRun: false)

        #expect(outcome.skipped.isEmpty)
        #expect(outcome.deduplicated.count == 1)
        #expect(outcome.reclaimedBytes == Int64(payload.count))

        // Every path still exists with identical content…
        for name in ["a.bin", "b.bin", "c.bin"] {
            let data = try Data(contentsOf: sandbox.appending(path: name))
            #expect(data == payload, "\(name) content must survive dedup")
        }
        // …but now everything shares one physical copy.
        let after = await DuplicateFinder.find(in: [sandbox])
        #expect(after.first?.physicalGroups.count == 1)

        // The replaced original's bytes are recoverable from the Trash.
        for record in outcome.deduplicated {
            let inTrash = try #require(record.trashLocation)
            #expect(FileManager.default.fileExists(atPath: inTrash.path))
            try? FileManager.default.removeItem(at: inTrash) // tidy up test litter
        }
    }

    @Test func policyViolationSkipsTargetNotAbort() async throws {
        let (sandbox, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sets = await DuplicateFinder.find(in: [sandbox])
        let set = try #require(sets.first)
        // Policy without the sandbox as an allowed root: the extra copy is
        // rejected per-item and reported as skipped, not a thrown abort.
        let outcome = CloneDeduplicator.deduplicate(
            set, policy: SafePathPolicy(), dryRun: false)
        #expect(outcome.deduplicated.isEmpty)
        #expect(outcome.skipped.count == 1)
        let after = await DuplicateFinder.find(in: [sandbox])
        #expect(after.first?.physicalGroups.count == 2, "rejected dedup must change nothing")
    }

    @Test func rejectsNonAPFSVolumePathIsSkipped() async throws {
        // A target that no longer exists is skipped (not a hard failure) and
        // the rest of the set is unaffected. We simulate by pointing the
        // policy at a sandbox whose extra copy we delete post-scan.
        let (sandbox, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let before = await DuplicateFinder.find(in: [sandbox])
        let set = try #require(before.first)
        // Delete one extra copy after the scan so replaceWithClone sees a
        // missing/changed file — must be skipped, not crash.
        let extra = set.physicalGroups.dropFirst().flatMap { $0 }.first!.url
        try FileManager.default.removeItem(at: extra)
        let policy = SafePathPolicy(extraAllowedRoots: [sandbox])
        let outcome = CloneDeduplicator.deduplicate(set, policy: policy, dryRun: false)
        #expect(outcome.deduplicated.isEmpty)
        #expect(outcome.skipped.count == 1)
    }
}

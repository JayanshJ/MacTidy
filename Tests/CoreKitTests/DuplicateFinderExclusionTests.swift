import Foundation
import Testing
@testable import CoreKit

/// `DuplicateFinder`'s whole-computer noise exclusion: hidden files,
/// build/VCS trees, and system roots must be skipped so results reflect
/// user data, not macOS's legitimate duplicates.
@Suite("DuplicateFinder exclusion")
struct DuplicateFinderExclusionTests {
    /// Builds a sandbox with two genuine duplicate documents plus a
    /// `.git`-style noise tree, a `node_modules` build tree, and a hidden
    /// `.DS_Store` — only the two documents should be reported as a set.
    func makeFixture() throws -> URL {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appending(path: "mactidy-dupexcl-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        // Two real duplicates in different subfolders.
        try fm.createDirectory(at: sandbox.appending(path: "Docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: sandbox.appending(path: "Projects/proj"), withIntermediateDirectories: true)
        try payload.write(to: sandbox.appending(path: "Docs/report.pdf"))
        try payload.write(to: sandbox.appending(path: "Projects/proj/report.pdf"))

        // Build/VCS noise that would falsely match if scanned.
        try fm.createDirectory(at: sandbox.appending(path: "Projects/proj/.git/objects"), withIntermediateDirectories: true)
        try payload.write(to: sandbox.appending(path: "Projects/proj/.git/objects/blob"))
        try fm.createDirectory(at: sandbox.appending(path: "Projects/proj/node_modules/pkg"), withIntermediateDirectories: true)
        try payload.write(to: sandbox.appending(path: "Projects/proj/node_modules/pkg/blob"))
        // Hidden file at the root.
        try Data("".utf8).write(to: sandbox.appending(path: ".DS_Store"))
        return sandbox
    }

    @Test func skipsHiddenBuildAndVCSNoise() async throws {
        let sandbox = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sets = await DuplicateFinder.find(in: [sandbox])
        // Exactly one set: the two report.pdf copies. The .git/node_modules
        // blobs and .DS_Store must not appear (the build-tree blobs would
        // otherwise form a second set, and .DS_Store might too).
        #expect(sets.count == 1)
        let set = try #require(sets.first)
        #expect(set.files.count == 2)
        #expect(set.files.allSatisfy { $0.url.lastPathComponent == "report.pdf" })
    }

    @Test func systemRootsAreNeverScanned() async throws {
        // Hand in a real system root alongside a user sandbox. The system
        // root must be filtered out entirely — if it were scanned the test
        // would either hang enumerating /System or surface system dupes.
        let sandbox = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sets = await DuplicateFinder.find(in: [URL(fileURLWithPath: "/System"), sandbox])
        #expect(sets.count == 1)
        #expect(sets.first?.files.count == 2)
    }

    @Test func defaultUserRootsAreUnderHomeAndExist() {
        let roots = DuplicateFinder.defaultUserRoots()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Every returned root is inside the home directory and actually
        // exists on disk (missing ones like ~/Movies on a headless setup
        // are dropped, so we only assert existence + home containment, not
        // an exact count).
        #expect(roots.allSatisfy { $0.path.hasPrefix(home + "/") })
        #expect(roots.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        // Documents and Downloads are near-universal on macOS.
        let names = Set(roots.map { $0.lastPathComponent })
        #expect(names.contains("Documents"))
        #expect(names.contains("Downloads"))
    }
}
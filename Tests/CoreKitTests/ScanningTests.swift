import Foundation
import Testing
@testable import CoreKit

@Suite("DiskScanner")
struct DiskScannerTests {
    func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    @Test func sizesMatchAllocatedBlocks() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // 3 files: 1 byte, 5000 bytes, and one in a subdirectory.
        try Data(count: 1).write(to: sandbox.appending(path: "one.bin"))
        try Data(count: 5000).write(to: sandbox.appending(path: "five-k.bin"))
        let sub = sandbox.appending(path: "sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: sub.appending(path: "ten-k.bin"))

        // Expected allocated size: sum of st_blocks * 512 per file (what du uses).
        var expected: Int64 = 0
        for path in ["one.bin", "five-k.bin", "sub/ten-k.bin"] {
            var st = stat()
            stat(sandbox.appending(path: path).path, &st)
            expected += Int64(st.st_blocks) * 512
        }

        #expect(DiskScanner.allocatedSize(of: sandbox) == expected)
    }

    @Test func symlinksAreNotFollowed() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let real = sandbox.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: real.appending(path: "file.bin"))
        // Symlink back into the same tree — following it would double-count.
        try FileManager.default.createSymbolicLink(
            at: sandbox.appending(path: "loop"), withDestinationURL: real)

        let direct = DiskScanner.allocatedSize(of: real)
        #expect(DiskScanner.allocatedSize(of: sandbox) == direct)
    }

    @Test func topLevelScanSortsLargestFirst() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let big = sandbox.appending(path: "big")
        let small = sandbox.appending(path: "small")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: big.appending(path: "x.bin"))
        try Data(count: 1000).write(to: small.appending(path: "y.bin"))

        let items = await DiskScanner.topLevelScan(root: sandbox)
        #expect(items.count == 2)
        #expect(items.first?.url.lastPathComponent == "big")
        #expect(items.first!.sizeBytes > items.last!.sizeBytes)
    }

    @Test func largeFilesFindsBigFilesAndSkipsBuildDirs() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // A big file at the top level…
        try Data(count: 200_000).write(to: sandbox.appending(path: "movie.bin"))
        // …a small file below the threshold…
        try Data(count: 10_000).write(to: sandbox.appending(path: "tiny.bin"))
        // …and a big file inside node_modules, which must be skipped so the
        // large-files list doesn't overlap the node_modules category.
        try FileManager.default.createDirectory(
            at: sandbox.appending(path: "node_modules/pkg"), withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: sandbox.appending(path: "node_modules/pkg/huge.bin"))

        let found = DiskScanner.largeFiles(under: [sandbox], minSize: 100_000)
        let names = Set(found.map(\.url.lastPathComponent))
        #expect(found.count == 1)
        #expect(names == ["movie.bin"])
        #expect(found.allSatisfy { $0.category == .bigFiles })
    }
}

@Suite("DuplicateFinder")
struct DuplicateFinderTests {
    @Test func findsExactContentDuplicates() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appending(path: "mactidy-dup-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox.appending(path: "nested"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let payload = Data((0..<20_000).map { UInt8($0 % 251) })
        try payload.write(to: sandbox.appending(path: "original.bin"))
        try payload.write(to: sandbox.appending(path: "copy.bin"))
        try payload.write(to: sandbox.appending(path: "nested/copy2.bin"))
        // Same size, different content — must NOT be grouped (partial hash
        // alone would miss a late difference; full hash catches it).
        var decoy = payload
        decoy[19_999] = 255
        try decoy.write(to: sandbox.appending(path: "decoy.bin"))
        // Unique size — discarded in stage 1.
        try Data(count: 5).write(to: sandbox.appending(path: "unique.bin"))

        let sets = await DuplicateFinder.find(in: [sandbox])
        #expect(sets.count == 1)
        let set = try #require(sets.first)
        #expect(set.files.count == 3)
        #expect(set.wastedBytes == Int64(payload.count) * 2)
        let names = Set(set.files.map(\.url.lastPathComponent))
        #expect(names == ["original.bin", "copy.bin", "copy2.bin"])
    }
}

import Foundation
import Testing
@testable import CoreKit

@Suite("BulkWalker")
struct BulkWalkerTests {
    func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-bulk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    /// The reference the walker must match: a FileManager walk summing
    /// `.totalFileAllocatedSize` of regular files.
    func enumeratorTotal(_ root: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in true })!
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Wide and deep enough that helper threads join the walk.
    func makeTree(at root: URL, branches: Int = 12, depth: Int = 3) throws {
        func fill(_ dir: URL, _ level: Int) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: 1000 * (level + 1)).write(to: dir.appending(path: "f.bin"))
            try Data(count: 10).write(to: dir.appending(path: ".hidden"))
            guard level < depth else { return }
            for i in 0..<(level == 0 ? branches : 3) {
                try fill(dir.appending(path: "d\(i)"), level + 1)
            }
        }
        try fill(root, 0)
    }

    @Test func parallelWalkMatchesEnumerator() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try makeTree(at: sandbox)

        let expected = enumeratorTotal(sandbox)
        #expect(expected > 0)
        // Repeat: helper scheduling varies run to run, totals must not.
        for _ in 0..<5 {
            #expect(DiskScanner.allocatedSize(of: sandbox) == expected)
        }
    }

    @Test func manyRootsKeepTheirOwnTotals() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let roots = (0..<6).map { sandbox.appending(path: "root\($0)") }
        for (i, root) in roots.enumerated() {
            try makeTree(at: root, branches: i + 1, depth: 2)
        }

        let sizes = BulkWalker.allocatedSizes(of: roots.map(\.path) + [sandbox.appending(path: "missing").path])
        #expect(sizes.count == roots.count + 1)
        for (root, size) in zip(roots, sizes) {
            #expect(size == enumeratorTotal(root))
        }
        #expect(sizes.last == 0)
    }

    @Test func symlinkedRootIsFollowedButNestedLinksAreNot() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let real = sandbox.appending(path: "real")
        try makeTree(at: real, branches: 2, depth: 1)
        // A link inside the tree pointing back at it must not double-count.
        try FileManager.default.createSymbolicLink(
            at: real.appending(path: "loop"), withDestinationURL: real)
        let link = sandbox.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let direct = DiskScanner.allocatedSize(of: real)
        #expect(direct == enumeratorTotal(real))
        #expect(DiskScanner.allocatedSize(of: link) == direct)
    }

    @Test func unreadableDirectoryIsSkipped() throws {
        let sandbox = try makeSandbox()
        let locked = sandbox.appending(path: "locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: sandbox)
        }
        try Data(count: 5000).write(to: sandbox.appending(path: "visible.bin"))
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: locked.appending(path: "hidden.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let visible = DiskScanner.allocatedSize(of: sandbox.appending(path: "visible.bin"))
        #expect(DiskScanner.allocatedSize(of: sandbox) == visible)
    }

    @Test func topLevelScanSizesEachChild() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        for i in 0..<5 { try makeTree(at: sandbox.appending(path: "child\(i)"), branches: i + 1, depth: 2) }
        try Data(count: 7000).write(to: sandbox.appending(path: "loose.bin"))

        let items = await DiskScanner.topLevelScan(root: sandbox)
        #expect(items.count == 6)
        for item in items where item.isDirectory {
            #expect(item.sizeBytes == enumeratorTotal(item.url))
        }
        #expect(items.map(\.sizeBytes) == items.map(\.sizeBytes).sorted(by: >))
    }
}

@Suite("Dev-roots cache")
struct DevRootsCacheTests {
    @Test func cacheAnswersEveryDevCategoryEvenWhenEmpty() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "mactidy-devcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let dev = home.appending(path: "Developer")
        try FileManager.default.createDirectory(at: dev.appending(path: "App/node_modules"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: dev.appending(path: "App/package.json"))
        try Data(count: 4096).write(to: dev.appending(path: "App/node_modules/x.js"))

        let scanner = CategoryScanner(home: home, devRoots: [dev], ignore: IgnoreList())
        let cache = await scanner.precomputeDevRootsCache()

        // A missing key would send that category back to its own full walk.
        #expect(Set(cache.keys) == CategoryScanner.devRootsCategories)
        #expect(cache[.nodeModules]?.count == 1)
        #expect(cache[.rustTargets] == [])
    }
}

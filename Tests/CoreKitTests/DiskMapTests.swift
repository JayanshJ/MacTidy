import Foundation
import Testing
@testable import CoreKit

@Suite("Disk Map")
struct DiskMapTests {
    @Test func cacheExpiresAndDetectsModification() {
        let cache = DiskMapSizeCache(lifetime: 10)
        let url = URL(fileURLWithPath: "/tmp/example")
        let date = Date(timeIntervalSince1970: 100)
        cache.store(42, for: url, modified: date, now: date)
        #expect(cache.size(for: url, modified: date, now: date.addingTimeInterval(9)) == 42)
        #expect(cache.size(for: url, modified: date, now: date.addingTimeInterval(10)) == nil)
        #expect(cache.size(for: url, modified: nil, now: date) == nil)
        cache.invalidate()
        #expect(cache.size(for: url, modified: date, now: date) == nil)
    }
    @Test func cancelledScanDoesNotEmitCompletedResults() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var results: [ScanItem] = []
            for await item in DiskMapScanner.scan(root: FileManager.default.homeDirectoryForCurrentUser, cache: DiskMapSizeCache()) {
                results.append(item)
            }
            return results
        }
        #expect(await task.value.isEmpty)
    }
    @Test func filtersTypeSizeAndAge() {
        let old = Date(timeIntervalSince1970: 100)
        let file = ScanItem(url: URL(fileURLWithPath: "/tmp/file"), sizeBytes: 100, isDirectory: false, lastModified: old)
        let folder = ScanItem(url: URL(fileURLWithPath: "/tmp/folder"), sizeBytes: 100, isDirectory: true, lastModified: nil)
        let filter = DiskMapFilter(kind: .files, minimumBytes: 50, modifiedBefore: Date(timeIntervalSince1970: 200))
        #expect(filter.matches(file))
        #expect(!filter.matches(folder))
        #expect(!DiskMapFilter(minimumBytes: 101).matches(file))
        #expect(!DiskMapFilter(modifiedBefore: old).matches(folder))
    }
    @Test func recursiveSearchFindsHiddenAndDoesNotFollowSymlinks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "mactidy-search-\(UUID())")
        try fm.createDirectory(at: root.appending(path: ".hidden/deep"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(count: 4096).write(to: root.appending(path: ".hidden/deep/Needle.txt"))
        try fm.createSymbolicLink(at: root.appending(path: "alias"), withDestinationURL: root.appending(path: ".hidden"))
        var found: [ScanItem] = []
        for await item in DiskMapSearch.search(root: root, name: "needle", cache: DiskMapSizeCache()) { found.append(item) }
        #expect(found.count == 1)
        #expect(found.first?.url.lastPathComponent == "Needle.txt")
    }
    @Test func selectionCollapsesOverlappingPaths() {
        let parent = ScanItem(url: URL(fileURLWithPath: "/tmp/project"), sizeBytes: 100, isDirectory: true)
        let child = ScanItem(url: URL(fileURLWithPath: "/tmp/project/file"), sizeBytes: 20, isDirectory: false)
        #expect(DiskMapSelection.adding(parent, to: [child]) == [parent])
        #expect(DiskMapSelection.adding(child, to: [parent]) == [parent])
    }
    @Test func managedPathsAndAncestorsAreProtected() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(HandledElsewhere.overlapsManagedLocation(home.appending(path: "Library/Application Support/Steam")))
        #expect(HandledElsewhere.overlapsManagedLocation(home.appending(path: "Parallels/machine")))
        #expect(!HandledElsewhere.overlapsManagedLocation(home.appending(path: "unrelated-mactidy-test")))
    }
}

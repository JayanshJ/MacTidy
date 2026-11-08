import CoreServices
import Foundation
import Testing
@testable import CoreKit

@Suite("Persistent disk map index")
struct DiskMapIndexTests {
    @Test func createsDeletesRenamesAndMovesMatchFreshScan() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "mactidy-index-test-\(UUID())")
        let root = base.appending(path: "root")
        let left = root.appending(path: "left")
        let right = root.appending(path: "right")
        try fm.createDirectory(at: left.appending(path: "nested"), withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data(count: 8192).write(to: left.appending(path: "nested/one"))
        try Data(count: 2048).write(to: right.appending(path: "two"))
        let future = Date(timeIntervalSinceNow: 86400)
        try fm.setAttributes([.modificationDate: future], ofItemAtPath: right.appending(path: "two").path)
        let indexFile = base.appending(path: "cache.json")
        let index = DiskMapIndex(file: indexFile)
        func verify(_ aggregates: [DiskMapIndex.Aggregate]) async {
            let fresh = await DiskScanner.topLevelScan(root: root)
            let allComplete = aggregates.allSatisfy { $0.complete }
            #expect(allComplete)
            let actual = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.item.url.lastPathComponent, $0.item.sizeBytes) })
            let expected = Dictionary(uniqueKeysWithValues: fresh.map { ($0.url.lastPathComponent, $0.sizeBytes) })
            #expect(actual == expected)
        }
        let initial = await index.refresh(root: root)
        await verify(initial)
        let initialRight = try #require(initial.first { $0.item.url.lastPathComponent == "right" })
        let newest = try #require(initialRight.newestModified)
        #expect(abs(newest.timeIntervalSince(future)) < 1)
        await index.waitForPendingWrites()
        #expect(DiskMapIndex(file: indexFile).cached(root: root)?.count == 2)
        try Data(count: 16384).write(to: left.appending(path: "nested/new"))
        try await Task.sleep(for: .milliseconds(300))
        await verify(await index.refresh(root: root))
        try fm.removeItem(at: left.appending(path: "nested/one"))
        try await Task.sleep(for: .milliseconds(300))
        await verify(await index.refresh(root: root))
        try fm.moveItem(at: left.appending(path: "nested/new"), to: left.appending(path: "nested/renamed"))
        try await Task.sleep(for: .milliseconds(300))
        await verify(await index.refresh(root: root))
        try fm.moveItem(at: left.appending(path: "nested/renamed"), to: right.appending(path: "moved"))
        try await Task.sleep(for: .milliseconds(300))
        let result = await index.refresh(root: root)
        await verify(result)
        let rightItem = try #require(result.first { $0.item.url.lastPathComponent == "right" })
        #expect(rightItem.itemCount == 2)
        #expect(rightItem.newestModified != nil)
    }
    @Test func corruptAndOversizedCacheFallBack() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "mactidy-index-corrupt-\(UUID())")
        let root = base.appending(path: "root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data(count: 4096).write(to: root.appending(path: "file"))
        let file = base.appending(path: "index.json")
        try Data("not json".utf8).write(to: file)
        let index = DiskMapIndex(file: file, maxBytes: 1024)
        #expect(index.cached(root: root) == nil)
        let result = await index.refresh(root: root)
        #expect(result.count == 1)
        await index.waitForPendingWrites()
        try Data(count: 2048).write(to: file)
        #expect(index.cached(root: root) == nil)
        let secondResult = await index.refresh(root: root)
        #expect(secondResult.count == 1)
    }
    @Test func droppedEventsAndRootChangesRequireFullRescan() {
        #expect(DiskMapJournal.requiresFullScan(flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)))
        #expect(DiskMapJournal.requiresFullScan(flags: UInt32(kFSEventStreamEventFlagKernelDropped)))
        #expect(DiskMapJournal.requiresFullScan(flags: UInt32(kFSEventStreamEventFlagUserDropped)))
        #expect(DiskMapJournal.requiresFullScan(flags: UInt32(kFSEventStreamEventFlagRootChanged)))
        #expect(DiskMapJournal.requiresFullScan(flags: UInt32(kFSEventStreamEventFlagUnmount)))
        #expect(!DiskMapJournal.requiresFullScan(flags: UInt32(kFSEventStreamEventFlagHistoryDone)))
    }
    @Test func cacheRejectsRootReplacementAndBoundsScopes() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "mactidy-index-scope-\(UUID())")
        let a = base.appending(path: "a"), b = base.appending(path: "b")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data(count: 100).write(to: a.appending(path: "file"))
        try Data(count: 100).write(to: b.appending(path: "file"))
        let index = DiskMapIndex(file: base.appending(path: "index"), maxScopes: 1)
        _ = await index.refresh(root: a)
        await index.waitForPendingWrites()
        #expect(index.cached(root: a) != nil)
        _ = await index.refresh(root: b)
        await index.waitForPendingWrites()
        #expect(index.cached(root: a) == nil)
        #expect(index.cached(root: b) != nil)
        try fm.moveItem(at: b, to: base.appending(path: "old-b"))
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        #expect(index.cached(root: b) == nil)
    }
    @Test func cleanRevisitsReuseOneMonitorAndChangesRefresh() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "mactidy-index-live-\(UUID())")
        let root = base.appending(path: "root")
        let folder = root.appending(path: "folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data(count: 4096).write(to: folder.appending(path: "a"))
        let index = DiskMapIndex(file: base.appending(path: "index"))
        for await _ in index.scan(root: root) {}
        try await Task.sleep(for: .milliseconds(500))
        var validating: Bool?
        // The initial filesystem events may arrive after the cold walk.
        // Let the journal catch up rather than assuming an exact delivery time.
        for _ in 0..<5 {
            for await event in index.scan(root: root) {
                if case .presented(_, let pending) = event { validating = pending }
            }
            if validating == false { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(validating == false)
        #expect(index.activeMonitorCount == 1)
        try Data(count: 16384).write(to: folder.appending(path: "b"))
        try await Task.sleep(for: .milliseconds(500))
        var final: [DiskMapIndex.Aggregate] = []
        for await event in index.scan(root: root) {
            if case .finished(let items, _) = event { final = items }
        }
        let fresh = await DiskScanner.topLevelScan(root: root)
        #expect(final.first?.item.sizeBytes == fresh.first?.sizeBytes)
        #expect(index.activeMonitorCount == 1)
    }
    @Test func relaunchPresentsHistoricalSnapshotBeforeValidation() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "mactidy-index-relaunch-\(UUID())")
        let root = base.appending(path: "root")
        try fm.createDirectory(at: root.appending(path: "dir"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data(count: 4096).write(to: root.appending(path: "dir/file"))
        let file = base.appending(path: "index")
        let initialIndex = DiskMapIndex(file: file)
        _ = await initialIndex.refresh(root: root)
        await initialIndex.waitForPendingWrites()
        try Data(count: 8192).write(to: root.appending(path: "dir/new"))
        try await Task.sleep(for: .milliseconds(300))
        let relaunched = DiskMapIndex(file: file)
        var events: [String] = []
        var final: [DiskMapIndex.Aggregate] = []
        for await event in relaunched.scan(root: root) {
            switch event {
            case .cached: events.append("cached")
            case .presented(_, let validating): events.append(validating ? "presented" : "clean")
            case .measured: break
            case .finished(let items, _): events.append("finished"); final = items
            }
        }
        #expect(events == ["cached", "presented", "finished"])
        let fresh = await DiskScanner.topLevelScan(root: root)
        #expect(final.first?.item.sizeBytes == fresh.first?.sizeBytes)
    }
    @Test func unchangedReplayDoesNotWalkChildren() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
            func increment() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "mactidy-index-unchanged-\(UUID())")
        let root = base.appending(path: "root")
        try fm.createDirectory(at: root.appending(path: "dir"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data(count: 4096).write(to: root.appending(path: "dir/file"))
        try await Task.sleep(for: .milliseconds(300))
        let indexFile = base.appending(path: "index")
        let writer = DiskMapIndex(file: indexFile)
        _ = await writer.refresh(root: root)
        await writer.waitForPendingWrites()
        let reader = DiskMapIndex(file: indexFile)
        let counter = Counter()
        let result = await reader.refresh(root: root) { _ in counter.increment() }
        #expect(result.count == 1)
        #expect(counter.count == 0)
    }
    @Test func costlyValidationFallsBackToAFullScan() {
        #expect(DiskMapIndex.shouldScanWholeScope(hasChanges: true, entries: 5, totalWeight: 100, dirtyWeight: 5, fullSeconds: 2, incrementalSeconds: 3))
        #expect(DiskMapIndex.shouldScanWholeScope(hasChanges: true, entries: 5, totalWeight: 100, dirtyWeight: 80, fullSeconds: nil, incrementalSeconds: nil))
        #expect(!DiskMapIndex.shouldScanWholeScope(hasChanges: false, entries: 5, totalWeight: 100, dirtyWeight: 100, fullSeconds: 2, incrementalSeconds: 3))
        #expect(!DiskMapIndex.shouldScanWholeScope(hasChanges: true, entries: 5, totalWeight: 100, dirtyWeight: 10, fullSeconds: 2, incrementalSeconds: 1))
    }
}

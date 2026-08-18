import Foundation
import Testing
@testable import CoreKit

@Suite("Recommendations ranking")
struct RecommendationsTests {
    @Test func flowActionTrashHasCorrectBytesAndTitle() {
        let item = ScanItem(url: URL(fileURLWithPath: "/tmp/c"), sizeBytes: 1_000_000,
                            isDirectory: true, category: .userCaches)
        let action = FlowAction.trash(items: [item], title: "DerivedData",
                                      why: "safe cache", icon: "internaldrive")
        #expect(action.reclaimableBytes == 1_000_000)
        #expect(action.title == "DerivedData")
        #expect(action.why == "safe cache")
        #expect(action.icon == "internaldrive")
        #expect(action.id.contains("tmp/c"))
    }

    @Test func flowActionUninstallComputesTotalBytes() {
        let app = InstalledApp(url: URL(fileURLWithPath: "/Apps/Foo.app"),
                               name: "Foo", bundleID: "com.foo", sizeBytes: 2_000_000)
        let leftover = ScanItem(url: URL(fileURLWithPath: "/tmp/l"), sizeBytes: 500_000,
                                isDirectory: true, category: .appSupport)
        let action = FlowAction.uninstall(app: app, leftovers: [leftover])
        #expect(action.reclaimableBytes == 2_500_000)
        #expect(action.title == "Uninstall Foo")
    }

    @Test func biggerItemsRankHigher() {
        let big = ScanItem(url: URL(fileURLWithPath: "/tmp/big"),
                           sizeBytes: 5_000_000_000, isDirectory: true, category: .userCaches)
        let small = ScanItem(url: URL(fileURLWithPath: "/tmp/small"),
                             sizeBytes: 50_000_000, isDirectory: true, category: .userCaches)
        let results = [
            CategoryResult(category: .userCaches, items: [big, small]),
        ]
        let ranked = Recommendations.ranked(from: results)
        #expect(ranked.first?.item == big)
    }

    @Test func preselectableOutranksSuggestOnlyAtSimilarSize() {
        // Same size; safe cache should rank above a suggest-only big file.
        let size: Int64 = 1_000_000_000
        let cache = ScanItem(url: URL(fileURLWithPath: "/tmp/c"), sizeBytes: size,
                             isDirectory: true, category: .userCaches)
        let big = ScanItem(url: URL(fileURLWithPath: "/tmp/f"), sizeBytes: size,
                           isDirectory: false, category: .bigFiles)
        let ranked = Recommendations.ranked(from: [
            CategoryResult(category: .userCaches, items: [cache]),
            CategoryResult(category: .bigFiles, items: [big]),
        ])
        #expect(ranked.first?.item == cache)
    }

    @Test func appSupportIsNeverRecommended() {
        let item = ScanItem(url: URL(fileURLWithPath: "/tmp/app"), sizeBytes: 9_000_000_000,
                            isDirectory: true, category: .appSupport)
        let ranked = Recommendations.ranked(from: [
            CategoryResult(category: .appSupport, items: [item]),
        ])
        #expect(ranked.isEmpty)
    }

    @Test func autoSelectOnlyIncludesPreselectable() {
        let cache = ScanItem(url: URL(fileURLWithPath: "/tmp/c"), sizeBytes: 1_000,
                             isDirectory: true, category: .userCaches)
        let big = ScanItem(url: URL(fileURLWithPath: "/tmp/f"), sizeBytes: 1_000,
                           isDirectory: false, category: .bigFiles)
        let ranked = Recommendations.ranked(from: [
            CategoryResult(category: .userCaches, items: [cache]),
            CategoryResult(category: .bigFiles, items: [big]),
        ])
        let auto = Recommendations.autoSelectableIDs(from: ranked)
        #expect(auto.contains(cache.id))
        #expect(!auto.contains(big.id))
    }

    @Test func staleItemsRankAboveFreshAtSameSize() {
        let size: Int64 = 1_000_000_000
        let fresh = ScanItem(url: URL(fileURLWithPath: "/tmp/a"), sizeBytes: size,
                             isDirectory: true, category: .nodeModules,
                             lastModified: Date.now)
        let stale = ScanItem(url: URL(fileURLWithPath: "/tmp/b"), sizeBytes: size,
                             isDirectory: true, category: .nodeModules,
                             lastModified: Date.now.addingTimeInterval(-365 * 86400))
        let ranked = Recommendations.ranked(from: [
            CategoryResult(category: .nodeModules, items: [fresh, stale]),
        ])
        #expect(ranked.first?.item == stale)
    }
}

@Suite("ScanHistory")
struct ScanHistoryTests {
    @Test func appendsAndCapsAndOrdersNewestFirst() throws {
        let fm = FileManager.default
        let storage = fm.temporaryDirectory.appending(path: "scan-history-\(UUID().uuidString).json")
        let history = ScanHistory(storageURL: storage)
        defer { try? fm.removeItem(at: storage) }

        history.append(ScanSnapshot(date: Date.now.addingTimeInterval(-200), reclaimableBytes: 100, itemCount: 1))
        history.append(ScanSnapshot(date: Date.now.addingTimeInterval(-100), reclaimableBytes: 200, itemCount: 2))
        history.append(ScanSnapshot(date: Date.now, reclaimableBytes: 150, itemCount: 3))

        let loaded = history.load()
        #expect(loaded.count == 3)
        #expect(loaded.first?.reclaimableBytes == 150) // newest first
        #expect(loaded.last?.reclaimableBytes == 100)

        for _ in 0..<ScanHistory.maxSnapshots {
            history.append(ScanSnapshot(reclaimableBytes: 1, itemCount: 1))
        }
        #expect(history.load().count == ScanHistory.maxSnapshots)
    }
}

@Suite("Log retention pruning")
struct LogRetentionTests {
    @Test func trashLogPrunesOldRecords() throws {
        let fm = FileManager.default
        let storage = fm.temporaryDirectory.appending(path: "trash-log-\(UUID().uuidString).json")
        let log = TrashLog(storageURL: storage)
        defer { try? fm.removeItem(at: storage) }

        let old = TrashRecord(original: URL(fileURLWithPath: "/tmp/old"),
                              trashLocation: URL(fileURLWithPath: "/Trash/old"),
                              date: Date.now.addingTimeInterval(-90 * 86400),
                              bytes: 100, kind: .deletion)
        let recent = TrashRecord(original: URL(fileURLWithPath: "/tmp/recent"),
                                 trashLocation: URL(fileURLWithPath: "/Trash/recent"),
                                 date: Date.now, bytes: 200, kind: .uninstall)
        log.append([old, recent])

        log.pruneOlderThan(days: 30)
        let loaded = log.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.bytes == 200)
    }

    @Test func cleanupLogPrunesOldEntries() throws {
        let fm = FileManager.default
        let storage = fm.temporaryDirectory.appending(path: "cleanup-log-\(UUID().uuidString).json")
        let log = CleanupLog(storageURL: storage)
        defer { try? fm.removeItem(at: storage) }

        log.append(CleanupEntry(date: Date.now.addingTimeInterval(-400 * 86400),
                                kind: .uninstall, reclaimedBytes: 5_000, itemCount: 2))
        log.append(CleanupEntry(date: Date.now, kind: .deletion, reclaimedBytes: 1_000, itemCount: 1))

        log.pruneOlderThan(days: 365)
        #expect(log.load().count == 1)
        #expect(log.totalReclaimed == 1_000)
    }

    @Test func zeroRetentionIsNoOp() throws {
        let fm = FileManager.default
        let storage = fm.temporaryDirectory.appending(path: "cleanup-log-\(UUID().uuidString).json")
        let log = CleanupLog(storageURL: storage)
        defer { try? fm.removeItem(at: storage) }

        log.append(CleanupEntry(date: Date.now.addingTimeInterval(-9999 * 86400),
                                kind: .deletion, reclaimedBytes: 1, itemCount: 1))
        log.pruneOlderThan(days: 0)
        #expect(log.load().count == 1)
    }
}
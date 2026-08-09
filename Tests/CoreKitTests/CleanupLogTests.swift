import Foundation
import Testing
@testable import CoreKit

@Suite("CleanupLog")
struct CleanupLogTests {
    @Test func recordsAccumulateAndTotal() throws {
        let fm = FileManager.default
        let storage = fm.temporaryDirectory.appending(path: "cleanup-log-\(UUID().uuidString).json")
        let log = CleanupLog(storageURL: storage)
        defer { try? fm.removeItem(at: storage) }

        log.append(CleanupEntry(kind: .deletion, reclaimedBytes: 1_000, itemCount: 3))
        log.append(CleanupEntry(kind: .dedup, reclaimedBytes: 2_500, itemCount: 5))

        let entries = log.load()
        #expect(entries.count == 2)
        #expect(log.totalReclaimed == 3_500)
        #expect(log.count == 2)
        // Newest first.
        #expect(entries.first?.kind == .dedup)
    }

    @Test func capsAtMaxEntries() throws {
        let fm = FileManager.default
        let storage = fm.temporaryDirectory.appending(path: "cleanup-log-\(UUID().uuidString).json")
        let log = CleanupLog(storageURL: storage)
        defer { try? fm.removeItem(at: storage) }

        for _ in 0..<(CleanupLog.maxEntries + 50) {
            log.append(CleanupEntry(kind: .deletion, reclaimedBytes: 1, itemCount: 1))
        }
        #expect(log.load().count == CleanupLog.maxEntries)
    }
}
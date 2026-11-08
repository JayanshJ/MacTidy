import Foundation
import Testing
@testable import CoreKit

@Suite("Disk Map benchmark")
struct DiskMapBenchmarkTests {
    @Test func benchmarkWhenRequested() async {
        guard ProcessInfo.processInfo.environment["MACTIDY_DISK_BENCHMARK"] == "1" else { return }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build")
        let start = ContinuousClock.now
        let items = await DiskScanner.topLevelScan(root: root)
        print("DISK_MAP_BASELINE items=\(items.count) elapsed=\(start.duration(to: .now))")
        let cache = DiskMapSizeCache()
        for await _ in DiskMapScanner.scan(root: root, cache: cache) {}
        let cachedStart = ContinuousClock.now
        var count = 0
        for await _ in DiskMapScanner.scan(root: root, cache: cache) { count += 1 }
        print("DISK_MAP_CACHED items=\(count) elapsed=\(cachedStart.duration(to: .now))")
    }
}

import Darwin
import Foundation
import Testing
@testable import CoreKit

/// Opt-in only; run through `make benchmark` so CLT gets Testing.framework.
@Suite("Disk Map benchmark")
struct DiskMapBenchmarkTests {
    private final class FirstResult: @unchecked Sendable {
        private let lock = NSLock()
        private let start = Date()
        private var elapsed: TimeInterval?
        func record() { lock.withLock { if elapsed == nil { elapsed = Date().timeIntervalSince(start) } } }
        var seconds: TimeInterval? { lock.withLock { elapsed } }
    }
    private func rssMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }
    private func countFiles(_ roots: [URL]) -> Int {
        let fm = FileManager.default
        var paths = Set<String>()
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { paths.insert(root.path); continue }
            guard let iter = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            for case let url as URL in iter {
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true { paths.insert(url.path) }
            }
        }
        return paths.count
    }
    @Test func benchmarkWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["MACTIDY_BENCHMARK"] == "1" else { return }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appending(path: "mactidy-benchmark-\(UUID())")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let roots = ["Library/Caches/Browser", "Library/Caches/Editor", ".npm/_cacache", "Developer/demo/node_modules/pkg"]
        let data = Data(repeating: 0x5a, count: 1024)
        for root in roots {
            for dir in 0..<40 {
                let folder = fixture.appending(path: "\(root)/part-\(dir)")
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in 0..<40 { try data.write(to: folder.appending(path: "file-\(file).dat")) }
            }
        }
        let homeOptIn = ProcessInfo.processInfo.environment["MACTIDY_BENCHMARK_HOME"] == "1"
        let home = homeOptIn ? fm.homeDirectoryForCurrentUser : fixture
        let fileCount = countFiles([home])
        print("BENCHMARK scope=\(homeOptIn ? "home" : "generated") files=\(fileCount) os=\(ProcessInfo.processInfo.operatingSystemVersionString) cpu=\(ProcessInfo.processInfo.processorCount)")
        print("| Scan | Pass | Full (s) | First result (s) | Files/s | Peak RSS (MiB) |")
        print("|---|---|---:|---:|---:|---:|")
        let indexFile = fm.temporaryDirectory.appending(path: "mactidy-benchmark-index-\(UUID()).json")
        defer { try? fm.removeItem(at: indexFile) }
        for pass in ["cold-app-cache", "warm-app-cache"] {
            let first = FirstResult(); let start = Date()
            var items: [ScanItem] = []
            let index = DiskMapIndex(file: indexFile)
            for await event in index.scan(root: home) {
                switch event {
                case .cached(let cached): if !cached.isEmpty { first.record() }
                case .presented: break
                case .measured: first.record()
                case .finished(let aggregates, _): items = aggregates.map(\.item)
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "| Disk Map | %@ | %.4f | %.4f | %.0f | %.1f |", pass, elapsed, first.seconds ?? elapsed, Double(fileCount) / max(elapsed, 0.000001), rssMB()))
            #expect(!items.isEmpty)
        }
        let scanner = CategoryScanner(home: home, devRoots: [home.appending(path: "Developer")], ignore: IgnoreList(), installedApps: InstalledApps(bundleIDs: [String]()))
        for pass in ["cold-app-cache", "warm-app-cache"] {
            let first = FirstResult(); let start = Date()
            let results = await scanner.scanAll(completed: { _ in first.record() })
            let elapsed = Date().timeIntervalSince(start)
            let matchedFiles = countFiles(results.flatMap(\.items).map(\.url))
            print(String(format: "| Categories | %@ | %.4f | %.4f | %.0f | %.1f |", pass, elapsed, first.seconds ?? elapsed, Double(matchedFiles) / max(elapsed, 0.000001), rssMB()))
            print("BENCHMARK category_matched_files=\(matchedFiles) categories=\(results.count)")
        }
    }
}

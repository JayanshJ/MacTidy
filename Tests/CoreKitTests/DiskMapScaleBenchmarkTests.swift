import Darwin
import Foundation
import Testing
@testable import CoreKit

@Suite("Disk Map scale benchmark")
struct DiskMapScaleBenchmarkTests {
    private func rss() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Double(r.ru_maxrss) / 1_048_576 }
    @Test func scaleBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACTIDY_SCALE_BENCHMARK"] == "1" else { return }
        let fm = FileManager.default
        let useHome = env["MACTIDY_BENCHMARK_HOME"] == "1"
        let fixture = fm.temporaryDirectory.appending(path: "mactidy-scale-fixture-v1")
        let root = useHome ? fm.homeDirectoryForCurrentUser : fixture
        if !useHome && !fm.fileExists(atPath: fixture.appending(path: ".complete").path) {
            for top in 0..<4 {
                for part in 0..<64 {
                    let folder = fixture.appending(path: "group-\(top)/part-\(part)/deep/a/b")
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    for file in 0..<800 { try Data([0x55]).write(to: folder.appending(path: "file-\(file)")) }
                }
            }
            try Data().write(to: fixture.appending(path: ".complete"))
        }
        print("SCALE scope=\(useHome ? "home" : "fixture-204800-files") system=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("| Run | Pass | Presented seconds | Background complete seconds | First seconds | Peak RSS MiB | Complete |")
        print("|---:|---|---:|---:|---:|---:|---|")
        let repetitions = max(1, Int(env["MACTIDY_SCALE_REPEATS"] ?? "1") ?? 1)
        for run in 1...repetitions {
            if env["MACTIDY_SCALE_COMPARE"] == "1" {
                let started = Date(); var first: Double?; var count = 0
                for await _ in DiskMapScanner.scan(root: root, cache: DiskMapSizeCache(lifetime: 0)) {
                    if first == nil { first = Date().timeIntervalSince(started) }; count += 1
                }
                let elapsed = Date().timeIntervalSince(started)
                print(String(format: "| %d | direct | %.6f | %.6f | %.6f | %.1f | yes |", run, elapsed, elapsed, first ?? elapsed, rss()))
                print("SCALE run=\(run) phase=direct entries=\(count)")
            }
            let cache = fm.temporaryDirectory.appending(path: "mactidy-scale-index-\(UUID()).json")
            defer { try? fm.removeItem(at: cache) }
            let warmIndex = DiskMapIndex(file: cache)
            for (name, index) in [("cold", warmIndex), ("warm", warmIndex), ("relaunch", DiskMapIndex(file: cache))] {
                if name == "warm" { try await Task.sleep(for: .milliseconds(400)) }
                if name == "relaunch" { await warmIndex.waitForPendingWrites() }
                let start = Date(); var first: Double?; var presented: Double?; var done = false; var count = 0
                for await event in index.scan(root: root) {
                    switch event {
                    case .cached(let values): if !values.isEmpty && first == nil { first = Date().timeIntervalSince(start) }
                    case .presented: if presented == nil { presented = Date().timeIntervalSince(start) }
                    case .measured: if first == nil { first = Date().timeIntervalSince(start) }
                    case .finished(let values, let complete): if presented == nil { presented = Date().timeIntervalSince(start) }; done = complete; count = values.count
                    }
                }
                let elapsed = Date().timeIntervalSince(start)
                print(String(format: "| %d | %@ | %.6f | %.6f | %.6f | %.1f | %@ |", run, name, presented ?? elapsed, elapsed, first ?? elapsed, rss(), done ? "yes" : "no"))
                print("SCALE run=\(run) phase=\(name) entries=\(count) persistent=\(fm.fileExists(atPath: cache.path))")
            }
        }
        if !useHome && env["MACTIDY_BENCHMARK_CLEAN"] == "1" { try? fm.removeItem(at: fixture) }
    }
}

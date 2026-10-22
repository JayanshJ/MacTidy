import Foundation
import Testing
@testable import CoreKit

@Suite("Registry gaps, ignore list, growers, running-app guard")
struct SmallWinsTests {
    func fakeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-sw-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func seed(_ home: URL, _ relative: String, bytes: Int = 4096) throws {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    // MARK: Registry gaps

    /// Specific caches inside ~/Library/Caches are listed once, under
    /// developer caches, and dropped from the per-app user caches.
    @Test func libraryCachesChildrenAreNotCountedTwice() async throws {
        let home = try fakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "Library/Caches/org.swift.swiftpm/repositories/x")
        try seed(home, "Library/Caches/ms-playwright/chromium-1140/chrome")
        try seed(home, "Library/Caches/com.example.app/data")
        try seed(home, "Library/Developer/Xcode/UserData/Previews/Simulator Devices/a")
        try seed(home, "Library/Developer/Xcode/UserData/KeyBindings/default.idekeybindings")

        let scanner = CategoryScanner(home: home, devRoots: [], ignore: IgnoreList())
        let user = await scanner.scan(.userCaches).items.map(\.url.lastPathComponent)
        let dev = await scanner.scan(.devCaches).items
        let devNames = Set(dev.map(\.url.lastPathComponent))

        #expect(user == ["com.example.app"])
        #expect(devNames.isSuperset(of: ["org.swift.swiftpm", "chromium-1140", "Previews", "KeyBindings"]))
        let previews = try #require(dev.first { $0.url.lastPathComponent == "Previews" })
        #expect(previews.risk == .safe)
        let bindings = try #require(dev.first { $0.url.lastPathComponent == "KeyBindings" })
        #expect(bindings.risk == .caution)
    }

    // MARK: Ignore list

    @Test func ignoreCoversPathAndEverythingInside() {
        var list = IgnoreList()
        list.add(URL(fileURLWithPath: "/Users/me/Developer/keep"))
        #expect(list.contains(URL(fileURLWithPath: "/Users/me/Developer/keep")))
        #expect(list.contains(URL(fileURLWithPath: "/Users/me/Developer/keep/node_modules")))
        #expect(!list.contains(URL(fileURLWithPath: "/Users/me/Developer/keeper")))
        list.add(URL(fileURLWithPath: "/Users/me/Developer/keep"))
        #expect(list.paths.count == 1)
        list.remove("/Users/me/Developer/keep")
        #expect(list.isEmpty)
    }

    @Test func ignoreListRoundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "mactidy-ignore-\(UUID().uuidString)"))
        var list = IgnoreList()
        list.add(URL(fileURLWithPath: "/tmp/a"))
        list.save(to: defaults)
        #expect(IgnoreList.load(from: defaults) == list)
    }

    @Test func scannerLeavesOutIgnoredItems() async throws {
        let home = try fakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, ".npm/_cacache/blob")
        try seed(home, ".cargo/registry/cache/crate")
        var ignore = IgnoreList()
        ignore.add(home.appending(path: ".npm"))

        let items = await CategoryScanner(home: home, devRoots: [], ignore: ignore).scan(.devCaches).items
        #expect(items.map(\.url.lastPathComponent) == ["registry"])
    }

    // MARK: Growers

    @Test func growersCompareWithAScanAtLeastADayOlder() {
        let now = Date()
        func snap(_ hoursAgo: Double, _ cats: [CoreKit.Category: Double]) -> ScanSnapshot {
            ScanSnapshot(date: now.addingTimeInterval(-hoursAgo * 3600), reclaimableBytes: 0, itemCount: 0,
                         categories: Dictionary(uniqueKeysWithValues: cats.map { ($0.key.rawValue, Int64($0.value * 1e9)) }))
        }
        let history = [
            snap(0, [.aiAgents: 6.0, .nodeModules: 4.0, .userCaches: 1.05]),
            snap(2, [.aiAgents: 1.0, .nodeModules: 1.0, .userCaches: 1.0]),   // too recent to compare
            snap(30, [.aiAgents: 4.8, .nodeModules: 4.5, .userCaches: 1.0]),
        ]
        let growth = ScanHistory.growers(in: history)
        #expect(growth.map(\.category) == [.aiAgents])
        #expect(growth.first?.delta == 1_200_000_000)
        #expect(growth.first?.current == 6_000_000_000)
    }

    @Test func oldSnapshotsWithoutCategoriesStillDecodeAndYieldNoGrowth() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","date":0,"reclaimableBytes":5,"itemCount":1}]"#
        let decoded = try JSONDecoder().decode([ScanSnapshot].self, from: Data(json.utf8))
        #expect(decoded.first?.categories == nil)
        #expect(ScanHistory.growers(in: decoded).isEmpty)
    }

    // MARK: Running-app guard

    @Test func warnsOnlyWhenTheAppIsOpenAndItsFoldersAreInvolved() {
        let home = URL(fileURLWithPath: "/Users/me")
        let derived = [home.appending(path: "Library/Developer/Xcode/DerivedData/App-abc")]
        let npm = [home.appending(path: ".npm")]

        let xcodeOpen: Set<String> = ["com.apple.dt.Xcode"]
        #expect(RunningAppGuard.conflicts(for: derived, runningBundleIDs: xcodeOpen, home: home).map(\.appName) == ["Xcode"])
        #expect(RunningAppGuard.conflicts(for: npm, runningBundleIDs: xcodeOpen, home: home).isEmpty)
        #expect(RunningAppGuard.conflicts(for: derived, runningBundleIDs: [], home: home).isEmpty)

        let sims = [home.appending(path: "Library/Developer/CoreSimulator/Devices/X")]
        let both: Set<String> = ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]
        #expect(Set(RunningAppGuard.conflicts(for: sims, runningBundleIDs: both, home: home).map(\.appName)) == ["Xcode", "Simulator"])
    }
}

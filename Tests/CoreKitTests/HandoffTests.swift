import Foundation
import Testing
@testable import CoreKit

@Suite("App memory advice")
struct AppMemoryTests {
    func process(_ pid: Int32 = 1, path: String = "/Applications/Editor.app", idle: Double = 600,
                 cpu: Double = 0.1, footprint: Int64? = 300_000_000) -> RunningProcess {
        RunningProcess(pid: pid, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                       appBundlePath: path, residentBytes: 900_000_000, cpuPercent: cpu,
                       idleSeconds: idle, physicalFootprintBytes: footprint)
    }

    @Test func nestedHelpersBelongToOutermostApp() {
        let result = ProcessScanner.attribute(comm: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper")
        #expect(result.bundlePath == "/Applications/Browser.app")
        #expect(result.name == "Browser")
    }

    @Test func activityRequiresObservedInactivityAndResetsAfterUse() {
        var activity = AppActivity()
        let now = Date(timeIntervalSince1970: 1000)
        let paths = ["/Applications/A.app", "/Applications/B.app"]
        #expect(activity.idleSeconds(for: paths[0], now: now) == 0)
        activity.observe(paths: paths, frontmost: paths[0], now: now)
        #expect(activity.idleSeconds(for: paths[0], now: now.addingTimeInterval(900)) == 0)
        #expect(activity.idleSeconds(for: paths[1], now: now.addingTimeInterval(301)) == 301)
        activity.observe(paths: paths, frontmost: paths[1], now: now.addingTimeInterval(900))
        #expect(activity.idleSeconds(for: paths[0], now: now.addingTimeInterval(1000)) == 100)
        #expect(activity.idleSeconds(for: paths[1], now: now.addingTimeInterval(1000)) == 0)
    }

    @Test func rollupUsesFootprintAndRequiresPressureAndAllHelpersIdle() {
        let processes = [process(1), process(2)]
        let apps = RunningAppMemory.grouped(processes)
        #expect(apps.count == 1)
        #expect(apps[0].footprintBytes == 600_000_000)
        #expect(MemoryAdvice.candidates(processes: processes, pressure: .normal, swapBytes: 0).isEmpty)
        #expect(MemoryAdvice.candidates(processes: processes, pressure: .warning, swapBytes: 0).count == 1)
        #expect(MemoryAdvice.candidates(processes: processes, pressure: nil, swapBytes: 2_000_000_000).count == 1)
        #expect(MemoryAdvice.candidates(processes: [process(1), process(2, idle: 0)], pressure: .critical, swapBytes: 0).isEmpty)
        #expect(MemoryAdvice.candidates(processes: [process(1, cpu: 0.6), process(2, cpu: 0.6)], pressure: .warning, swapBytes: 0).isEmpty)
    }

    @Test func unknownMemoryDoesNotFallBackToRSSAndSystemAppsStayProtected() {
        #expect(RunningAppMemory.grouped([process(1), process(2, footprint: nil)])[0].footprintBytes == nil)
        #expect(MemoryAdvice.candidates(processes: [process(path: "/System/Applications/Settings.app")], pressure: .critical, swapBytes: 0).isEmpty)
        #expect(MemoryAdvice.candidates(processes: [process(path: "/Applications/MacTidy.app")], pressure: .critical, swapBytes: 0).isEmpty)
    }

    @Test func startupMemoryUsesExactExecutableAndUnknownStaysUnknown() {
        let process = RunningProcess(pid: 30, name: "Agent", appBundlePath: nil, residentBytes: 500,
            cpuPercent: 0, idleSeconds: 0, physicalFootprintBytes: 100, executablePath: "/opt/agent")
        #expect(ProcessScanner.footprint(forExecutable: "/opt/agent", in: [process]) == 100)
        #expect(ProcessScanner.footprint(forExecutable: "/other/agent", in: [process]) == nil)
    }

    @Test func newLaunchDoesNotInheritOldIdleTime() {
        var activity = AppActivity()
        let path = "/Applications/A.app", start = Date(timeIntervalSince1970: 1000)
        activity.observe(paths: [path], frontmost: nil, now: start)
        activity.observe(paths: [path], frontmost: nil, launchDates: [path: start.addingTimeInterval(600)],
                         now: start.addingTimeInterval(601))
        #expect(activity.idleSeconds(for: path, now: start.addingTimeInterval(602)) == 1)
    }

    @Test func growthRequiresHoursAndSustainedIncreaseAndResetsForRestart() {
        var history = AppMemoryHistory()
        let start = Date(timeIntervalSince1970: 1000)
        for index in 0..<5 {
            history.record(RunningAppMemory.grouped([process(1, footprint: 300_000_000 + Int64(index) * 100_000_000)]),
                           now: start.addingTimeInterval(Double(index) * 1800))
        }
        #expect(history.growth(for: "/Applications/Editor.app") == 400_000_000)
        history.record(RunningAppMemory.grouped([process(200)]), now: start.addingTimeInterval(7300))
        #expect(history.growth(for: "/Applications/Editor.app") == nil)
    }

    @Test func liveFootprintReadIsPositiveOrUnavailable() {
        if let footprint = ProcessScanner.physicalFootprint(pid: ProcessInfo.processInfo.processIdentifier) {
            #expect(footprint > 0)
        }
        #expect(ProcessScanner.physicalFootprint(pid: -1) == nil)
    }

    @Test func aiCannotBypassIdleOrPressureGates() {
        let raw: [String: Any] = ["insights": [["reasoning": "Quit it", "action": "quit", "kind": "memory", "quitApps": ["Editor"]]]]
        let healthy = SystemSnapshot(categories: [], memory: nil, processes: [process()], memoryPressure: .normal)
        #expect(InsightResolver.resolve(raw, snapshot: healthy).isEmpty)
        let active = SystemSnapshot(categories: [], memory: nil, processes: [process(idle: 0)], memoryPressure: .critical)
        #expect(InsightResolver.resolve(raw, snapshot: active).isEmpty)
    }
}

@Suite("Target cleanup and honest reporting")
struct TargetCleanupTests {
    let home = URL(fileURLWithPath: "/Users/tester")
    func item(_ path: String, size: Int64 = 1_000_000_000, category: CoreKit.Category = .userCaches,
              finding: String? = nil) -> ScanItem {
        ScanItem(url: home.appending(path: path), sizeBytes: size, isDirectory: true,
                 category: category, finding: finding)
    }

    @Test func costOrderNeverSelectsCautionAndFiltersProtectedPaths() {
        let safe = item("Library/Caches/one")
        let output = item("Developer/P/dist", category: .jsBuildDirs, finding: BuildOutput.finding)
        let secret = item(".ssh")
        let results = [CategoryResult(category: .userCaches, items: [safe, secret]),
                       CategoryResult(category: .jsBuildDirs, items: [output])]
        let proposal = TargetCleanup(results: results, targetBytes: 2_000_000_000, policy: SafePathPolicy(home: home))
        #expect(proposal.items.map(\.id) == [safe.id, output.id])
        #expect(proposal.initialSelection == [safe.id])
        #expect(output.risk == .caution)
    }

    @Test func overlappingItemsCannotInflateProposal() {
        let parent = item("Library/Caches/App", size: 2_000_000_000)
        let child = item("Library/Caches/App/child")
        let results = [CategoryResult(category: .userCaches, items: [parent, child, parent])]
        let proposal = TargetCleanup(results: results, targetBytes: 10_000_000_000, policy: SafePathPolicy(home: home))
        #expect(proposal.items.count == 1)
        #expect(proposal.proposedBytes == 2_000_000_000)
    }

    @Test func invalidAndExtremeTargetsAreRejected() {
        #expect(TargetCleanup.bytes(fromGB: "5,5") == 5_500_000_000)
        for input in ["", "nan", "inf", "-1", "0", "1e99", "one"] {
            #expect(TargetCleanup.bytes(fromGB: input) == nil)
        }
    }

    @Test func returnedCleanupNeedsRecentRecordedPathAndSize() {
        let now = Date()
        let cache = item("Library/Caches/App")
        let entry = CleanupEntry(date: now.addingTimeInterval(-86400), kind: .deletion,
            reclaimedBytes: cache.sizeBytes, itemCount: 1, paths: [cache.url.path])
        #expect(RecurringCleanup.returned(items: [cache], history: [entry], now: now) == [cache])
        #expect(RecurringCleanup.returned(items: [cache], history: [entry], now: now.addingTimeInterval(8 * 86400)).isEmpty)
        #expect(RecurringCleanup.returned(items: [cache], history: [], now: now).isEmpty)
    }

    @Test func oldCleanupHistoryStillDecodes() throws {
        let entry = CleanupEntry(kind: .deletion, reclaimedBytes: 1, itemCount: 1)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "paths")
        let decoded = try JSONDecoder().decode(CleanupEntry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.paths == nil)
    }

    @Test func apfsAccountingUsesOnlyBootContainerSystemVolumes() throws {
        let plist: [String: Any] = ["Containers": [
            ["Volumes": [["MountPoint": "/Volumes/External", "Roles": ["System"], "CapacityInUse": 9000]]],
            ["Volumes": [
                ["MountPoint": "/System/Volumes/Data", "Roles": ["Data"], "CapacityInUse": 4000],
                ["MountPoint": "/", "Roles": ["System"], "CapacityInUse": 1000],
                ["Roles": ["Recovery"], "CapacityInUse": 200],
            ]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let parts = try #require(DiskAccounting.systemVolumes(in: data))
        #expect(parts.reduce(0) { $0 + $1.bytes } == 1200)
        #expect(DiskAccounting.systemVolumes(in: Data()) == nil)
    }

    @Test func finderErrorsAndMeasurementsAreHonestWithoutEmptyingAnything() {
        #expect(TrashEmptying.interpret(succeeded: true, error: "") == .completed)
        #expect(TrashEmptying.interpret(succeeded: false, error: "User canceled (-128)") == .cancelled)
        #expect(TrashEmptying.interpret(succeeded: false, error: "Not authorized (-1743)") == .failed("Not authorized"))
        #expect(TrashSpaceMeasurement(before: 200, after: 100).change == -100)
        #expect(TrashSpaceMeasurement(before: nil, after: 100).change == nil)
        #expect(DiskAccounting.snapshotCount(in: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-03-120000.local\n") == 1)
    }
}

@Suite("Build output discovery")
struct BuildOutputTests {
    @Test func ignoredOutputsAreCautionTrackedFilesAndResourcesAreKept() async throws {
        let home = try CategoryScannerTests().makeFakeHome()
        let project = home.appending(path: "Developer/App")
        let fm = FileManager.default
        for name in ["dist", "out", "resources", ".build", "App.xcodeproj"] {
            try fm.createDirectory(at: project.appending(path: name), withIntermediateDirectories: true)
            try Data(repeating: 42, count: 8192).write(to: project.appending(path: name + "/blob"))
        }
        try "dist/\nout/\nresources/\n".write(to: project.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        #expect(Shell.run("/usr/bin/git", ["--no-optional-locks", "-C", project.path, "init"])?.succeeded == true)
        #expect(Shell.run("/usr/bin/git", ["--no-optional-locks", "-C", project.path, "add", "-f", "out/blob"])?.succeeded == true)
        let scanner = CategoryScanner(home: home, devRoots: [home.appending(path: "Developer"), project], ignore: IgnoreList())
        let cache = await scanner.precomputeDevRootsCache()
        let js = await scanner.scan(.jsBuildDirs, devRootsCache: cache)
        #expect(js.items.map { $0.url.lastPathComponent } == ["dist"])
        #expect(js.items.allSatisfy { $0.risk == .caution && !$0.isPreselectable })
        let swift = await scanner.scan(.swiftBuildDirs)
        #expect(swift.items.count == 1)
        #expect(swift.items.first?.risk == .caution)
        let large = DiskScanner.largeFiles(under: [project], minSize: 1,
            excludedDirectories: cache.values.flatMap { $0 }.map(\.url))
        #expect(!large.contains { $0.url.path.contains("/dist/") })
        #expect(large.contains { $0.url.path.contains("/resources/") })
        #expect(large.contains { $0.url.path.contains("/out/") })
        let uncached = await scanner.scan(.jsBuildDirs)
        #expect(uncached.items == js.items)
        let paths = cache.values.flatMap { $0 }.map(\.url.path)
        #expect(paths.count == Set(paths).count)
        // Fixtures remain under the OS-managed temporary directory; no real files are touched.
    }
}

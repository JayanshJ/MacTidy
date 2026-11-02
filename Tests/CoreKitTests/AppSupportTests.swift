import Foundation
import Testing
@testable import CoreKit

@Suite("Application Support: smart scan, tiers, protect list, owners")
struct AppSupportTests {
    let fm = FileManager.default

    func makeHome() throws -> URL {
        let home = fm.temporaryDirectory.appending(path: "mactidy-appsupport-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "Library/Application Support"), withIntermediateDirectories: true)
        return home
    }

    /// A folder holding one file big enough to clear the 1 MB row minimum.
    func fill(_ home: URL, _ path: String, bytes: Int = 1_200_000) throws {
        let dir = home.appending(path: "Library/Application Support/" + path)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: dir.appending(path: "data.bin"))
    }

    func file(_ home: URL, _ path: String) throws {
        let url = home.appending(path: "Library/Application Support/" + path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 100).write(to: url)
    }

    func scan(_ home: URL, installed: [String] = []) async -> [ScanItem] {
        await CategoryScanner(home: home, devRoots: [], ignore: IgnoreList(),
                              installedApps: InstalledApps(bundleIDs: installed)).scan(.appSupport).items
    }

    /// Backdates a folder and everything directly in it.
    func age(_ home: URL, _ path: String, days: Double) throws {
        let dir = home.appending(path: "Library/Application Support/" + path)
        let date = Date().addingTimeInterval(-days * 86_400)
        for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) + [dir] {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    func relative(_ items: [ScanItem], _ home: URL) -> Set<String> {
        let root = home.appending(path: "Library/Application Support").standardizedFileURL.path + "/"
        return Set(items.map { $0.url.standardizedFileURL.path.replacingOccurrences(of: root, with: "") })
    }

    // MARK: Scanner

    @Test func electronCachesAreListedButAppDataIsNot() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Slack/Cache")
        try fill(home, "Slack/Code Cache")
        try fill(home, "Slack/GPUCache")
        try fill(home, "Slack/Local Storage")
        try fill(home, "Slack/IndexedDB")
        try file(home, "Slack/Cookies")

        let items = await scan(home)
        #expect(relative(items, home) == ["Slack/Cache", "Slack/Code Cache", "Slack/GPUCache"])
        #expect(items.allSatisfy { $0.risk == .safe && $0.isPreselectable && $0.detail == "Slack" })
    }

    @Test func aFolderNamedCacheNeedsChromiumSiblings() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "PlainApp/Cache")
        try fill(home, "PlainApp/Documents")

        #expect(await scan(home).isEmpty)
    }

    @Test func browserServiceWorkerCacheIsCautionAndProfileIsUntouched() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try file(home, "Google/Chrome/Local State")
        try fill(home, "Google/Chrome/Default/Code Cache")
        try fill(home, "Google/Chrome/Default/Service Worker/CacheStorage")
        try fill(home, "Google/Chrome/Default/Service Worker/Database")
        try file(home, "Google/Chrome/Default/Login Data")

        let items = await scan(home)
        #expect(relative(items, home) == [
            "Google/Chrome/Default/Code Cache", "Google/Chrome/Default/Service Worker/CacheStorage",
        ])
        let storage = try #require(items.first { $0.url.lastPathComponent == "CacheStorage" })
        #expect(storage.risk == .caution)
        #expect(!storage.isPreselectable)
        #expect(storage.detail == "Google Chrome")
    }

    @Test func electronServiceWorkerCacheIsSafe() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Slack/Code Cache")
        try fill(home, "Slack/Service Worker/CacheStorage")

        let storage = try #require(await scan(home).first { $0.url.lastPathComponent == "CacheStorage" })
        #expect(storage.risk == .safe)
    }

    @Test func claudeVMIsCautionAndOnlyOldVersionsAreListed() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Claude/vm_bundles/claudevm.bundle")
        try fill(home, "Claude/claude-code/2.1.308")
        try fill(home, "Claude/claude-code/2.1.309")
        try fill(home, "Claude/claude-code/2.1.10")

        let items = await scan(home)
        #expect(relative(items, home) == [
            "Claude/vm_bundles", "Claude/claude-code/2.1.308", "Claude/claude-code/2.1.10",
        ])
        #expect(items.first { $0.url.lastPathComponent == "vm_bundles" }?.risk == .caution)
        #expect(items.first { $0.url.lastPathComponent == "2.1.308" }?.risk == .safe)
    }

    @Test func nestedPartitionsAreFoundAndBackupsSkipped() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Claude/Partitions/preview/Cache")
        try fill(home, "Claude/Partitions/preview/Code Cache")
        try fill(home, "MobileSync/Backup/0001/Cache")
        try fill(home, "MobileSync/Backup/0001/Code Cache")

        #expect(relative(await scan(home), home) == [
            "Claude/Partitions/preview/Cache", "Claude/Partitions/preview/Code Cache",
        ])
    }

    @Test func tinyCachesAndSymlinksAreSkipped() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Spline/Code Cache")
        try fill(home, "Spline/GPUCache", bytes: 10_000)
        let elsewhere = home.appending(path: "elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(count: 1_200_000).write(to: elsewhere.appending(path: "big.bin"))
        try fm.createSymbolicLink(at: home.appending(path: "Library/Application Support/Spline/Cache"),
                                  withDestinationURL: elsewhere)

        #expect(relative(await scan(home), home) == ["Spline/Code Cache"])
    }

    @Test func outermostDropsNestedAndDuplicateCandidates() {
        let a = URL(fileURLWithPath: "/x/App/Cache")
        let nested = URL(fileURLWithPath: "/x/App/Cache/Cache_Data")
        let b = URL(fileURLWithPath: "/x/App/Code Cache")
        #expect(AppSupportScanner.outermost([nested, b, a, a]).map(\.path) == [a.path, b.path])
    }

    // MARK: Tiers and recommendations

    @Test func wholeAppFoldersAreCautionAndNeverRecommended() {
        let folder = ScanItem(url: URL(fileURLWithPath: "/Users/x/Library/Application Support/Steam"),
                              sizeBytes: 9_000_000_000, isDirectory: true, category: .appSupport)
        #expect(AppSupportRules.insight(for: folder.url) == nil)
        #expect(folder.risk == .caution)
        #expect(!folder.isPreselectable)
        #expect(Recommendations.ranked(from: [CategoryResult(category: .appSupport, items: [folder])]).isEmpty)
        #expect(Recommendations.suggestOnly(from: [CategoryResult(category: .appSupport, items: [folder])]).count == 1)
    }

    @Test func safeCachesAreRecommendedAndPreselected() throws {
        let cache = ScanItem(url: URL(fileURLWithPath: "/Users/x/Library/Application Support/Slack/Code Cache"),
                             sizeBytes: 300_000_000, isDirectory: true, category: .appSupport, detail: "Slack")
        #expect(Category.appSupport.isPreselectable)
        #expect(cache.isPreselectable)
        let rec = try #require(Recommendations.ranked(from: [CategoryResult(category: .appSupport, items: [cache])]).first)
        #expect(rec.reason == .safeCache)
    }

    @Test func insightNamesOwnersAndExplains() throws {
        let support = "/Users/x/Library/Application Support/"
        let vs = try #require(AppSupportRules.insight(for: URL(fileURLWithPath: support + "Code/CachedExtensionVSIXs")))
        #expect(vs.owner == "VS Code")
        #expect(vs.explanation.contains("VS Code"))
        #expect(AppSupportRules.owner(of: URL(fileURLWithPath: support + "Google/Chrome/Default/GPUCache")) == "Google Chrome")
        #expect(AppSupportRules.owner(of: URL(fileURLWithPath: support + "Google/DriveFS")) == "Google")
        #expect(AppSupportRules.displayPath(of: URL(fileURLWithPath: support + "Claude/Cache")) == "Claude › Cache")
        #expect(AppSupportRules.insight(for: URL(fileURLWithPath: "/Users/x/Library/Caches/Slack/Cache")) == nil)
    }

    // MARK: Protect list

    @Test func systemAndICloudDataInsideAppSupportIsProtected() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let policy = SafePathPolicy(home: home)
        let support = home.appending(path: "Library/Application Support")
        for path in ["com.apple.TCC", "com.apple.TCC/TCC.db", "CloudDocs/session", "MacTidy", "Knowledge"] {
            guard case .failure(.protectedAppData) = policy.classify(support.appending(path: path)) else {
                Issue.record("expected \(path) to be protected"); continue
            }
        }
    }

    @Test func browserSecretsAreProtectedButAppFoldersStillUninstall() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let policy = SafePathPolicy(home: home)
        let support = home.appending(path: "Library/Application Support")
        guard case .failure(.protectedAppData) = policy.classify(support.appending(path: "Google/Chrome/Default/Login Data")),
              case .failure(.protectedAppData) = policy.classify(support.appending(path: "Slack/Cookies")) else {
            Issue.record("profile secrets must be refused"); return
        }
        // Uninstalling an app trashes its whole folder, cookies and all.
        #expect((try? policy.classify(support.appending(path: "Slack")).get()) != nil)
        #expect((try? policy.classify(support.appending(path: "Slack/Code Cache")).get()) != nil)
        // The same names elsewhere are not special.
        #expect((try? policy.classify(home.appending(path: "Documents2/History")).get()) != nil)
    }

    // MARK: Running owners

    @Test func runningOwnerIsFoundByBundleIDOrName() {
        let home = URL(fileURLWithPath: "/Users/x")
        let support = "/Users/x/Library/Application Support/"
        let claude = RunningApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude")
        let spline = RunningApp(bundleID: "design.spline.app", name: "Spline")
        let finder = RunningApp(bundleID: "com.apple.finder", name: "Finder")
        let urls = [
            URL(fileURLWithPath: support + "Claude/Cache"),
            URL(fileURLWithPath: support + "Claude/Code Cache"),
            URL(fileURLWithPath: support + "Spline/GPUCache"),
            URL(fileURLWithPath: support + "Slack/Cache"),
        ]
        let found = RunningAppGuard.conflicts(for: urls, running: [claude, spline, finder], home: home)
        #expect(Set(found.map(\.bundleID)) == ["com.anthropic.claudefordesktop", "design.spline.app"])
        #expect(found.count == 2)
    }

    @Test func chromeIsMatchedThroughItsVendorFolder() {
        let home = URL(fileURLWithPath: "/Users/x")
        let url = URL(fileURLWithPath: "/Users/x/Library/Application Support/Google/Chrome/Default/Code Cache")
        let chrome = RunningApp(bundleID: "com.google.Chrome", name: "Google Chrome")
        #expect(RunningAppGuard.conflicts(for: [url], running: [chrome], home: home).map(\.bundleID) == ["com.google.Chrome"])
    }

    @Test func fixedRulesStillApply() {
        let home = URL(fileURLWithPath: "/Users/x")
        let url = URL(fileURLWithPath: "/Users/x/Library/Developer/Xcode/DerivedData/App-abc")
        let xcode = RunningApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")
        #expect(RunningAppGuard.conflicts(for: [url], running: [xcode], home: home).map(\.bundleID) == ["com.apple.dt.Xcode"])
    }

    // MARK: Phase 2: leftovers, versions, virtual disks

    @Test func folderOfARemovedAppIsALeftover() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "com.example.gone")
        try fill(home, "com.example.gone/Cache")
        try fill(home, "com.example.gone/Code Cache")
        try age(home, "com.example.gone", days: 60)

        let items = await scan(home)
        #expect(relative(items, home) == ["com.example.gone"])
        let leftover = try #require(items.first)
        #expect(leftover.finding == "leftover")
        #expect(leftover.detail == AppSupportRules.removedAppsGroup)
        #expect(leftover.risk == .caution)
        #expect(!leftover.isPreselectable)
        #expect(AppSupportRules.insight(for: leftover)?.label == "Leftover app data")
    }

    @Test func leftoverNeedsAgeAndNoOwner() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        for name in ["com.example.recent", "com.example.installed", "com.vendor.shared", "com.apple.someservice"] {
            try fill(home, name)
        }
        for name in ["com.example.installed", "com.vendor.shared", "com.apple.someservice"] {
            try age(home, name, days: 90)
        }
        // Recent: still in use by something. Installed: its app is here.
        // Shared: another app from the same vendor is installed. Apple: a
        // background service with no app of its own.
        let items = await scan(home, installed: ["com.example.installed", "com.vendor.app"])
        #expect(items.isEmpty)
    }

    @Test func installedAppsOwnHelpersAndSharedFolders() {
        let apps = InstalledApps(bundleIDs: ["com.raycast.macos", "com.openai.codex"])
        #expect(apps.owns("com.raycast.shared"))
        #expect(apps.owns("com.openai.codex.installer"))
        #expect(apps.owns("COM.RAYCAST.MACOS"))
        #expect(!apps.owns("com.example.gone"))
        #expect(AppSupportRules.isBundleIdentifier("com.example.gone"))
        #expect(!AppSupportRules.isBundleIdentifier("Claude"))
        #expect(!AppSupportRules.isBundleIdentifier("zoom.us"))
        #expect(!AppSupportRules.isBundleIdentifier("com..bad"))
    }

    @Test func olderVersionsBesideANewerOneAreCaution() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        for version in ["1.2.0", "1.3.0", "1.10.0"] { try fill(home, "SomeTool/runtimes/\(version)") }
        // Year folders are someone's archive, not versions.
        for year in ["2023", "2024"] { try fill(home, "Photos Lib/\(year)") }

        let items = await scan(home)
        #expect(relative(items, home) == ["SomeTool/runtimes/1.2.0", "SomeTool/runtimes/1.3.0"])
        #expect(items.allSatisfy { $0.finding == "olderVersion" && $0.risk == .caution && $0.detail == "SomeTool" })
    }

    @Test func namedVersionRulesWinOverTheGenericFinding() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Claude/claude-code/2.1.308")
        try fill(home, "Claude/claude-code/2.1.309")

        let item = try #require(await scan(home).first)
        #expect(item.finding == nil)
        #expect(item.risk == .safe)
    }

    @Test func virtualMachineBundlesAreDanger() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "UTM/vms/Linux.utm")

        let item = try #require(await scan(home).first)
        #expect(relative([item], home) == ["UTM/vms/Linux.utm"])
        #expect(item.finding == "virtualDisk")
        #expect(item.risk == .danger)
        #expect(!item.isPreselectable)
    }

    @Test func findingSurvivesASavedScanAndOldScansStillLoad() throws {
        let item = ScanItem(url: URL(fileURLWithPath: "/Users/x/Library/Application Support/com.example.gone"),
                            sizeBytes: 5, isDirectory: true, category: .appSupport,
                            detail: AppSupportRules.removedAppsGroup, finding: "leftover")
        let decoded = try JSONDecoder().decode(ScanItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.finding == "leftover")
        #expect(decoded.risk == .caution)

        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        old.removeValue(forKey: "finding")
        let legacy = try JSONDecoder().decode(ScanItem.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.finding == nil)
    }

    // MARK: Phase 2: attribution and AI context

    @Test func preferencesAndSavedStateMatchTheirApp() {
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Test.app"),
                               name: "Test", bundleID: "com.example.test", sizeBytes: 1)
        let snapshot = MatchSnapshot(byBundleID: ["com.example.test": app], byName: ["Test": app])
        #expect(snapshot.match(name: "com.example.test.plist")?.bundleID == "com.example.test")
        #expect(snapshot.match(name: "com.example.test.savedState")?.bundleID == "com.example.test")
        #expect(snapshot.match(name: "com.example.testing.plist") == nil)
    }

    @Test func aiContextNamesTheAppOnlyWithPathsAllowed() {
        let item = ScanItem(url: URL(fileURLWithPath: "/Users/x/Library/Application Support/Claude/vm_bundles"),
                            sizeBytes: 10_000_000_000, isDirectory: true, category: .appSupport, detail: "Claude")
        let blind = AdvisorPrompts.explainUser(item: item, sendFilePaths: false)
        // No folder name, no owner: the generic category text may still name
        // example apps, but nothing ties this item to one.
        #expect(blind.contains("Cowork virtual machine"))
        #expect(!blind.contains("vm_bundles"))
        #expect(!blind.contains("Claude's folder"))
        let open = AdvisorPrompts.explainUser(item: item, sendFilePaths: true)
        #expect(open.contains("Claude's folder"))
    }
}

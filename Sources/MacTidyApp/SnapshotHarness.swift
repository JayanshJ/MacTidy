import SwiftUI
import CoreKit

/// Design QA: `MacTidy --snapshot <dir> [--only a,b]` loads fixture data,
/// visits every screen in light and dark, renders the window to PNG, quits.
/// Never scans, trashes, checks for updates or starts the monitor.
@MainActor
enum SnapshotHarness {
    static var outputDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }
    static var isActive: Bool { outputDir != nil }

    private static var only: Set<String>? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--only"), i + 1 < args.count else { return nil }
        return Set(args[i + 1].split(separator: ",").map(String.init))
    }

    static func run(state: AppState) async {
        guard let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.title == "MacTidy" }) else {
            NSApp.terminate(nil); return
        }
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let granted = FDAStatus(granted: true, issues: [],
                                signing: SigningInfo(identifier: "com.jayansh.mactidy", cdhash: nil, isAdHoc: false))
        let results = Fixtures.results()
        state.projects = Fixtures.projects(results)
        // Two scans a few days apart so Overview shows what's growing.
        var older = results
        older = older.map { r in
            let shrink: Double = r.category == .aiAgents ? 0.55 : (r.category == .nodeModules ? 0.7 : 1)
            return CategoryResult(category: r.category, items: r.items.map {
                ScanItem(url: $0.url, sizeBytes: Int64(Double($0.sizeBytes) * shrink), isDirectory: true, category: $0.category)
            })
        }
        // Claude's Cowork VM arrived and a game went in, so the folder-level
        // nudges show alongside a category's.
        let elsewhere = Fixtures.elsewhere()
        let folders = ScanHistory.folderTotals(results: results, elsewhere: elsewhere, fullDiskAccess: true)
        var olderFolders = folders
        olderFolders["appSupport:Claude"] = 800_000_000
        olderFolders["elsewhere:steamGames"] = 62_000_000_000
        let history = [ScanSnapshot(results: results, folders: folders),
                       ScanSnapshot(results: older, date: Date().addingTimeInterval(-7 * 86_400), folders: olderFolders)]
        func main(_ section: SidebarItem, drill: CoreKit.Category? = nil, project: String? = nil,
                  showingElsewhere: Bool = false, scanHistory: [ScanSnapshot]? = nil) -> () -> Void {
            {
                state.selectedProjectID = project
                state.fdaStatus = granted
                state.flowPhase = .dashboard
                state.categoryResults = results
                state.elsewhereItems = elsewhere
                state.showingElsewhere = showingElsewhere
                state.scanHistory = scanHistory ?? history
                state.appSupportBytes = 23_400_000_000 + 97_000_000_000
                state.isScanningCategories = false
                state.section = section
                state.drilledCategory = drill
            }
        }
        var screens: [(String, () -> Void)] = [
            ("onboarding", {
                state.fdaSkipped = false
                state.fdaStatus = FDAStatus(granted: false, issues: [.staleGrant, .unstableSignature],
                                            signing: SigningInfo(identifier: "com.jayansh.mactidy", cdhash: "ab", isAdHoc: true))
            }),
            ("welcome", {
                state.fdaStatus = granted
                state.flowPhase = .welcome
                state.categoryResults = []
            }),
            ("scanning", {
                state.fdaStatus = granted
                state.categoryResults = []
                state.flowPhase = .scanning
                state.section = .overview
                state.scanTotal = 34
                state.scanCompleted = 19
                state.scanProgress = "Scanning Xcode DerivedData…"
                state.scanPartial = Array(results.prefix(9))
            }),
            ("overview", main(.overview)),
            ("overview-nohistory", main(.overview, scanHistory: [ScanSnapshot(results: results)])),
            ("cleanup", main(.cleanup)),
            ("cleanup-elsewhere", main(.cleanup, showingElsewhere: true)),
            ("cleanup-detail", main(.cleanup, drill: .xcodeDerivedData)),
            ("cleanup-node", main(.cleanup, drill: .nodeModules)),
            ("cleanup-appsupport", main(.cleanup, drill: .appSupport)),
            ("project-detail", main(.projects, project: "/Users/demo/Developer/storefront")),
        ]
        for item in SidebarItem.allCases where item != .overview && item != .cleanup {
            screens.append((item.rawValue, main(item)))
        }
        if let only { screens = screens.filter { only.contains($0.0) } }

        for (mode, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: name)
            for (screen, setup) in screens {
                setup()
                try? await Task.sleep(for: .milliseconds(1200))
                // A screen whose minimum size exceeds the window would force
                // the real window to grow off-screen; flag it.
                if let host = window.contentView?.subviews.first,
                   host.fittingSize.height > window.contentLayoutRect.height + 1 {
                    FileHandle.standardError.write("LAYOUT OVERFLOW \(screen)-\(mode): needs \(host.fittingSize.height)pt\n".data(using: .utf8)!)
                }
                capture(window, to: dir.appending(path: "\(screen)-\(mode).png"))
            }
        }
        // Standalone surfaces: rendered in a throwaway window of their own.
        let standalone: [(String, CGSize, AnyView)] = [
            ("settings", CGSize(width: 640, height: 600), AnyView(SettingsView())),
            ("sheet-confirm", CGSize(width: 600, height: 540),
             AnyView(DeletionConfirmationSheet(title: "Clean everything that's safe?",
                                               plan: DeletionPlan(items: Array(results.flatMap(\.items).filter(\.isPreselectable).prefix(8)))))),
            ("menubar", CGSize(width: 300, height: 420), AnyView(MenuBarPanel())),
            // Sits below the fold on the Overview and Cleanup pages.
            ("elsewhere-link", CGSize(width: 760, height: 150),
             AnyView(HandledElsewhereLink().padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.canvas))),
        ].filter { only?.contains($0.0) ?? true }
        state.categoryResults = results
        state.elsewhereItems = elsewhere
        for (mode, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: name)
            for (screen, size, view) in standalone {
                let host = NSHostingView(rootView: view.environment(state).tint(Theme.accent))
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = host
                w.orderFront(nil)
                try? await Task.sleep(for: .milliseconds(1200))
                capture(w, to: dir.appending(path: "\(screen)-\(mode).png"))
                w.orderOut(nil)
            }
        }
        NSApp.terminate(nil)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Plausible scan results for screenshots. Paths are fake; nothing reads them.
private enum Fixtures {
    static func projects(_ results: [CategoryResult]) -> [DevProject] {
        let now = Date()
        let items = results.flatMap(\.items)
        func project(_ name: String, days: Double, git: Double, dirty: Bool = false, unpushed: Int? = 0,
                     stale: Bool = false, subject: String) -> DevProject {
            let url = URL(fileURLWithPath: "/Users/demo/Developer/\(name)")
            let mine = items.filter { $0.url.path.hasPrefix(url.path + "/") }
            var trees = [DevProject.Worktree(path: url, branch: "main", isMain: true, isPrunable: false)]
            if stale {
                trees.append(.init(path: URL(fileURLWithPath: "/Users/demo/.codex/worktrees/fix-auth"), branch: "fix-auth", isMain: false, isPrunable: true))
            }
            let date = now.addingTimeInterval(-days * 86_400)
            return DevProject(url: url, branch: "main", lastCommit: date, lastCommitSubject: subject, lastActivity: date,
                              gitBytes: Int64(git * 1_000_000_000), artifacts: mine, worktrees: trees,
                              isDirty: dirty, unpushedCommits: unpushed, containsOtherRepos: false)
        }
        return [
            project("ripgrep-fork", days: 240, git: 0.3, unpushed: nil, subject: "Try SIMD line splitting"),
            project("storefront", days: 130, git: 0.6, unpushed: 2, stale: true, subject: "Checkout: handle declined cards"),
            project("api-gateway", days: 40, git: 0.2, subject: "Bump rate limits"),
            project("landing", days: 3, git: 0.1, dirty: true, subject: "New hero copy"),
            project("dotfiles", days: 12, git: 0.02, subject: "zsh: faster prompt"),
        ].sorted { $0.score(now: now) > $1.score(now: now) }
    }

    static func elsewhere() -> [ScanItem] {
        let entries: [(String, String, Double, Bool)] = [
            ("steamGames", "Library/Application Support/Steam/steamapps/common/Elden Ring", 49, true),
            ("steamGames", "Library/Application Support/Steam/steamapps/common/Hades II", 13, true),
            ("steamGames", "Library/Application Support/Steam/steamapps/common/Balatro", 35, true),
            ("dockerDisk", "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", 38, false),
            ("utm", "Library/Containers/com.utmapp.UTM/Data/Documents/Ubuntu 24.04.utm", 21, true),
            ("messages", "Library/Messages/Attachments", 14.6, true),
            ("whatsapp", "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media", 3.2, true),
            ("iCloudDrive", "Library/Mobile Documents", 8.4, true),
            ("vagrant", ".vagrant.d/boxes", 2.7, true),
        ]
        return entries.map { rule, path, gigabytes, isDirectory in
            ScanItem(url: URL(fileURLWithPath: "/Users/demo/" + path), sizeBytes: Int64(gigabytes * 1_000_000_000),
                     isDirectory: isDirectory, detail: HandledElsewhere.rule(id: rule)?.owner,
                     lastModified: Date().addingTimeInterval(-40 * 86_400), finding: rule)
        }
    }

    static func results() -> [CategoryResult] {
        let home = "/Users/demo"
        func items(_ category: CoreKit.Category, _ entries: [(String, Double, String?)]) -> CategoryResult {
            CategoryResult(category: category, items: entries.enumerated().map { i, e in
                ScanItem(url: URL(fileURLWithPath: home + "/" + e.0), sizeBytes: Int64(e.1 * 1_000_000_000),
                         isDirectory: true, category: category, detail: e.2,
                         lastModified: Date().addingTimeInterval(-Double(i + 1) * 86400 * 9))
            })
        }
        return [
            items(.xcodeDerivedData, [
                ("Library/Developer/Xcode/DerivedData/MacTidy-dhqkxuzbfa", 6.4, nil),
                ("Library/Developer/Xcode/DerivedData/Orbit-gxnmyyeqws", 4.1, nil),
                ("Library/Developer/Xcode/DerivedData/Weather-bkjxzsojmd", 2.2, nil),
                ("Library/Developer/Xcode/DerivedData/ModuleCache.noindex", 0.9, nil)]),
            items(.nodeModules, [
                ("Developer/storefront/node_modules", 1.9, "storefront"),
                ("Developer/storefront/packages/ui/node_modules", 0.6, "storefront"),
                ("Developer/landing/node_modules", 0.8, "landing"),
                ("Developer/api-gateway/node_modules", 1.1, "api-gateway")]),
            items(.userCaches, [
                ("Library/Caches/com.spotify.client", 1.3, nil),
                ("Library/Caches/Google", 0.7, nil),
                ("Library/Caches/com.tinyspeck.slackmacgap", 0.4, nil)]),
            items(.aiAgents, [
                (".codex/worktrees/layer-model-settings", 1.0, "Codex worktree (may hold unmerged work)"),
                (".cache/codex-runtimes", 1.7, "Codex runtimes (re-downloaded)"),
                (".claude/debug", 0.3, "Claude Code debug logs")]),
            items(.devCaches, [
                (".npm", 2.8, "npm cache"), (".cargo/registry", 1.6, "Cargo registry"),
                ("go/pkg/mod", 0.9, "Go module cache")]),
            items(.homebrewCache, [("Library/Caches/Homebrew", 1.4, nil)]),
            items(.xcodeDeviceSupport, [
                ("Library/Developer/Xcode/iOS DeviceSupport/iPhone16,1 18.2", 3.3, nil),
                ("Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.5", 2.9, nil)]),
            items(.rustTargets, [("Developer/ripgrep-fork/target", 2.4, "ripgrep-fork")]),
            items(.oldInstallers, [("Downloads/Docker.dmg", 0.6, nil), ("Downloads/Figma-122.dmg", 0.3, nil)]),
            items(.iosBackups, [("Library/Application Support/MobileSync/Backup/00008110", 18.2, "iPhone")]),
            items(.bigFiles, [("Downloads/screen-recording.mov", 4.2, nil), ("Downloads/dataset.parquet", 2.1, nil)]),
            items(.crashReports, [("Library/Logs/DiagnosticReports/Xcode-2026-10-01.ips", 0.02, nil)]),
            items(.appSupport, [
                ("Library/Application Support/Claude/vm_bundles", 10.7, "Claude"),
                ("Library/Application Support/Claude/Cache", 0.35, "Claude"),
                ("Library/Application Support/Claude/claude-code/2.1.308", 0.27, "Claude"),
                ("Library/Application Support/Claude/Code Cache", 0.2, "Claude"),
                ("Library/Application Support/com.apple.wallpaper/aerials", 1.9, "Wallpapers"),
                ("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage", 1.4, "Google Chrome"),
                ("Library/Application Support/Google/Chrome/Default/Code Cache", 0.3, "Google Chrome"),
                ("Library/Application Support/Code/CachedData", 0.9, "VS Code"),
                ("Library/Application Support/Code/CachedExtensionVSIXs", 0.4, "VS Code"),
                ("Library/Application Support/Slack/Service Worker/CacheStorage", 0.8, "Slack")]).adding([
                ScanItem(url: URL(fileURLWithPath: home + "/Library/Application Support/com.example.oldeditor"),
                         sizeBytes: 2_300_000_000, isDirectory: true, category: .appSupport,
                         detail: AppSupportRules.removedAppsGroup,
                         lastModified: Date().addingTimeInterval(-200 * 86_400), finding: "leftover"),
                ScanItem(url: URL(fileURLWithPath: home + "/Library/Application Support/JetBrains/Toolbox/apps/IDEA/2024.3.1"),
                         sizeBytes: 1_600_000_000, isDirectory: true, category: .appSupport,
                         detail: "JetBrains", lastModified: Date().addingTimeInterval(-120 * 86_400),
                         finding: "olderVersion")]),
        ]
    }
}

private extension CategoryResult {
    func adding(_ more: [ScanItem]) -> CategoryResult {
        CategoryResult(category: category, items: items + more)
    }
}

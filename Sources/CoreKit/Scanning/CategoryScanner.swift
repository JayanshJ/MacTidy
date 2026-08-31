import Foundation

public struct CategoryResult: Identifiable, Sendable, Codable, Equatable {
    public let category: Category
    public let items: [ScanItem]
    public var id: Category { category }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    public init(category: Category, items: [ScanItem]) {
        self.category = category
        self.items = items
    }
}

/// Read-only scanner for the curated cleanup presets. Where the spec named a
/// single folder (DerivedData, user caches) we surface its *children* so the
/// user gets per-project / per-app granularity instead of all-or-nothing.
public struct CategoryScanner: Sendable {
    public var home: URL
    public var devRoots: [URL]
    public var installerMinAgeDays: Int

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        devRoots: [URL] = CategoryScanner.defaultDevRoots,
        installerMinAgeDays: Int = 30
    ) {
        self.home = home
        self.devRoots = devRoots
        self.installerMinAgeDays = installerMinAgeDays
    }

    /// Conventional project folders that exist on this machine.
    public static var defaultDevRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Developer", "Projects", "Code", "src", "dev"]
            .map { home.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func scanAll(
        progress: (@Sendable (Category) -> Void)? = nil,
        completed: (@Sendable (CategoryResult) -> Void)? = nil
    ) async -> [CategoryResult] {
        // Run the single-pass dev-roots walk ONCE before dispatching
        // categories to parallel tasks. This eliminates the 7+ redundant
        // full-tree walks the old per-category approach did.
        let cache = devRootsScan()
        return await withTaskGroup(of: CategoryResult.self) { group in
            for category in Category.allCases {
                if Task.isCancelled { break }
                let cacheRef = cache
                group.addTask {
                    if Task.isCancelled { return CategoryResult(category: category, items: []) }
                    progress?(category)
                    return await scanCached(category, devRootsCache: cacheRef)
                }
            }
            var results: [CategoryResult] = []
            for await result in group {
                completed?(result)
                results.append(result)
            }
            return results.sorted { $0.totalBytes > $1.totalBytes }
        }
    }

    public func scan(_ category: Category) async -> CategoryResult {
        await scanCached(category, devRootsCache: [:])
    }

    /// The real scan method. `devRootsCache` carries pre-computed results
    /// from a single-pass dev-roots walk (populated by `scanAll`). When
    /// empty (e.g. when scanning a single category), the build-dir categories
    /// fall back to the old per-category walks.
    private func scanCached(_ category: Category, devRootsCache: [Category: [ScanItem]]) async -> CategoryResult {
        let items: [ScanItem]
        switch category {
        case .xcodeDerivedData:
            items = await children(of: "Library/Developer/Xcode/DerivedData", category)
        case .xcodeDeviceSupport:
            items = await children(of: "Library/Developer/Xcode/iOS DeviceSupport", category)
        case .simulatorCaches:
            items = wholeDir(home.appending(path: "Library/Developer/CoreSimulator/Caches"), category)
        case .simulatorRuntimes:
            items = await children(of: "Library/Developer/CoreSimulator/Images", category)
        case .userCaches:
            items = await children(of: "Library/Caches", category)
        case .homebrewCache:
            items = homebrewCache()
        case .nodeModules:
            items = devRootsCache[.nodeModules] ?? buildDirs(named: "node_modules", siblingMarkers: ["package.json"], category: .nodeModules)
        case .rustTargets:
            items = devRootsCache[.rustTargets] ?? buildDirs(named: "target", siblingMarkers: ["Cargo.toml"], category: .rustTargets)
        case .podDirs:
            items = devRootsCache[.podDirs] ?? buildDirs(named: "Pods", siblingMarkers: ["Podfile"], category: .podDirs)
        case .swiftBuildDirs:
            items = devRootsCache[.swiftBuildDirs] ?? buildDirs(named: ".build", siblingMarkers: ["Package.swift"], category: .swiftBuildDirs)
        case .gradleBuildDirs:
            items = devRootsCache[.gradleBuildDirs] ?? buildDirs(named: "build", siblingMarkers: ["build.gradle", "build.gradle.kts"], category: .gradleBuildDirs)
        case .pythonCaches:
            items = devRootsCache[.pythonCaches] ?? pythonCaches()
        case .jsBuildDirs:
            items = devRootsCache[.jsBuildDirs] ?? jsBuildDirs()
        case .containerCaches:
            items = await containerCaches()
        case .xcodeArchives:
            items = await xcodeArchives()
        case .mailDownloads:
            items = await mailDownloads()
        case .mavenTarget:
            items = devRootsCache[.mavenTarget] ?? buildDirs(named: "target", siblingMarkers: ["pom.xml"], category: .mavenTarget)
        case .phpVendor:
            items = devRootsCache[.phpVendor] ?? buildDirs(named: "vendor", siblingMarkers: ["composer.json"], category: .phpVendor)
        case .flutterDartTool:
            items = devRootsCache[.flutterDartTool] ?? buildDirs(named: ".dart_tool", siblingMarkers: ["pubspec.yaml"], category: .flutterDartTool)
        case .unityLibrary:
            items = devRootsCache[.unityLibrary] ?? unityLibrary()
        case .androidSystemImages:
            items = await androidSystemImages()
        case .staleScreenshots:
            items = staleScreenshots()
        case .oldInstallers:
            items = oldInstallers()
        case .iosBackups:
            items = await iosBackups()
        case .devCaches:
            items = await devCaches()
        case .appSupport:
            items = await appSupportHoarders()
        case .bigFiles:
            items = await bigFiles()
        case .simulatorDevices:
            items = await children(of: "Library/Developer/CoreSimulator/Devices", category)
        case .systemLogs:
            items = await children(of: "Library/Logs", category)
        case .crashReports:
            items = await children(of: "Library/Logs/DiagnosticReports", category)
        case .savedAppState:
            items = await children(of: "Library/Saved Application State", category)
        case .httpStorages:
            items = await children(of: "Library/HTTPStorages", category)
        case .groupContainers:
            items = await children(of: "Library/Group Containers", category)
        }
        return CategoryResult(category: category, items: items)
    }

    private func children(of relativePath: String, _ category: Category) async -> [ScanItem] {
        await DiskScanner.topLevelScan(root: home.appending(path: relativePath), category: category)
    }

    private func wholeDir(_ url: URL, _ category: Category) -> [ScanItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = DiskScanner.allocatedSize(of: url)
        guard size > 0 else { return [] }
        return [ScanItem(url: url, sizeBytes: size, isDirectory: true, category: category)]
    }

    private func homebrewCache() -> [ScanItem] {
        guard let brew = Shell.find("brew"),
              let output = Shell.run(brew, ["--cache"]), output.succeeded else { return [] }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return [] }
        return wholeDir(URL(fileURLWithPath: path), .homebrewCache)
    }

    private func oldInstallers() -> [ScanItem] {
        let downloads = home.appending(path: "Downloads")
        let cutoff = Date.now.addingTimeInterval(-Double(installerMinAgeDays) * 86400)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: downloads, includingPropertiesForKeys: Array(keys)
        ) else { return [] }

        return entries.compactMap { url in
            guard ["dmg", "pkg", "xip", "iso"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff
            else { return nil }
            return ScanItem(url: url, sizeBytes: Int64(values.totalFileAllocatedSize ?? 0),
                            isDirectory: false, category: .oldInstallers,
                            lastModified: modified)
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Local device backups made by Finder syncing. Each backup folder's
    /// Info.plist carries the device name and last-backup date so the user
    /// can tell a stale backup from tonight's.
    private func iosBackups() async -> [ScanItem] {
        let root = home.appending(path: "Library/Application Support/MobileSync/Backup")
        let backups = await DiskScanner.topLevelScan(root: root, category: .iosBackups)
        return backups.filter(\.isDirectory).map { item in
            var deviceName: String?
            var lastBackup: Date?
            let infoPlist = item.url.appending(path: "Info.plist")
            if let data = try? Data(contentsOf: infoPlist),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] {
                deviceName = plist["Device Name"] as? String
                lastBackup = plist["Last Backup Date"] as? Date
            }
            return ScanItem(url: item.url, sizeBytes: item.sizeBytes, isDirectory: true,
                            category: .iosBackups, detail: deviceName,
                            lastModified: lastBackup ?? item.lastModified)
        }
    }

    /// Developer package-manager caches that live outside ~/Library/Caches
    /// (caches inside it are already covered by the user-caches category,
    /// so listing them here would double-count).
    private func devCaches() async -> [ScanItem] {
        let candidates: [(relativePath: String, label: String)] = [
            (".npm", "npm cache"),
            (".cargo/registry", "Cargo registry"),
            (".gradle/caches", "Gradle caches"),
            // Gradle wrapper distributions — downloaded Gradle runtimes, one
            // per version. Often 100+ MB each; regenerable on next build.
            (".gradle/wrapper/dists", "Gradle wrapper distributions"),
            ("Library/pnpm/store", "pnpm store"),
            ("go/pkg/mod", "Go module cache"),
            (".m2/repository", "Maven repository"),
            (".yarn/cache", "Yarn cache"),
            (".terraform.d/plugin-cache", "Terraform plugin cache"),
            // sbt's Coursier/Ivy cache (Scala builds). Can be several GB.
            (".sbt", "sbt cache"),
            // Coursier cache (modern Scala, distinct from .sbt).
            (".coursier/cache", "Coursier cache"),
            // Bun package cache (home-rooted; not under ~/Library/Caches so
            // no overlap with the userCaches category).
            (".bun/install/cache", "Bun cache"),
            // XDG cache dir — pip, mypy, pytest, pre-commit, httpie, etc. all
            // live here. Counted once at the root so we don't double-
            // count its children individually.
            (".cache", "XDG cache (~/.cache)"),
            // Deno's cache directory (home-rooted variant; the
            // ~/Library/Caches/deno location, if present, is covered by
            // userCaches).
            (".deno", "Deno cache"),
            // iOS device sync logs — per-device crash/sync logs, safe to trash,
            // Xcode recreates on next device connect.
            ("Library/Developer/Xcode/iOS DeviceLogs", "iOS Device Logs"),
            // CocoaPods global spec/config cache. Regenerable via `pod install`.
            (".cocoapods", "CocoaPods cache"),
            // Fastlane cache (build artifacts, downloaded metadata). Regenerable.
            (".fastlane", "Fastlane cache"),
            // Ollama model weights — can be many GB. Removing means re-pulling
            // the model via `ollama pull <model>`.
            (".ollama/models", "Ollama models"),
            // Colima Docker VM disk image. Removing means re-provisioning on
            // next `colima start`.
            (".colima", "Colima VM disk"),
            // Lima VM disk images (Colima's backend). Same reclaim story.
            (".lima", "Lima VM disk"),
            // VS Code extensions. Regenerable — reinstall from the Extensions panel.
            (".vscode/extensions", "VS Code extensions"),
            // Android AVD data (emulator devices). Regenerable — recreate via
            // Android Studio AVD Manager.
            (".android/avd", "Android AVD data"),
            // Android SDK cache (downloads, temp). Regenerable.
            (".android/cache", "Android SDK cache"),
            // Xcode user data (breakpoints, snapshots, schemes). Safe to clear
            // but may lose custom schemes — labeled so the user can judge.
            ("Library/Developer/Xcode/UserData", "Xcode UserData"),
        ]
        let home = self.home
        return await withTaskGroup(of: ScanItem?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let url = home.appending(path: candidate.relativePath)
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    let size = DiskScanner.allocatedSize(of: url)
                    guard size > 0 else { return nil }
                    return ScanItem(url: url, sizeBytes: size, isDirectory: true,
                                    category: .devCaches, detail: candidate.label)
                }
            }
            var items: [ScanItem] = []
            for await item in group where item != nil {
                items.append(item!)
            }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    /// Largest per-app data folders in ~/Library/Application Support. These
    /// hold real app state, so the category is suggest-only — the user must
    /// judge each one. Apple's own subfolders are listed too (for awareness)
    /// but trashing them is rarely safe; the SafePathPolicy still allows
    /// trashing arbitrary subfolders here, so the explanation warns loudly.
    private func appSupportHoarders() async -> [ScanItem] {
        let root = home.appending(path: "Library/Application Support")
        let items = await DiskScanner.topLevelScan(root: root, category: .appSupport)
        // Surface the top 30 by size — there can be dozens of tiny ones.
        return Array(items.prefix(30))
    }

    /// Largest individual files under the user's Downloads and dev roots.
    /// Library is excluded so this doesn't overlap the dedicated Library
    /// categories (caches, backups, Application Support, …). Build/VCS trees
    /// are skipped inside `largeFiles` for the same reason. Suggest-only.
    private func bigFiles() async -> [ScanItem] {
        let roots = [home.appending(path: "Downloads")] + devRoots
        return await Task.detached {
            DiskScanner.largeFiles(under: roots, minSize: 100 * 1024 * 1024)
        }.value
    }

    /// Single-pass walk of all dev roots that classifies every directory
    /// against ALL build-dir + Python-cache + Unity patterns in one enumeration.
    /// Returns a dictionary keyed by category, so the individual `scan(_:)`
    /// cases for nodeModules, rustTargets, podDirs, swiftBuildDirs,
    /// gradleBuildDirs, mavenTarget, phpVendor, flutterDartTool, jsBuildDirs,
    /// pythonCaches, and unityLibrary all share one walk instead of each
    /// re-walking the entire tree (the old code did 7+ redundant full walks).
    private func devRootsScan() -> [Category: [ScanItem]] {

        // Build-dir targets: (dirName, markers, category).
        let buildTargets: [(String, [String], Category)] = [
            ("node_modules", ["package.json"], .nodeModules),
            ("target", ["Cargo.toml"], .rustTargets),
            ("Pods", ["Podfile"], .podDirs),
            (".build", ["Package.swift"], .swiftBuildDirs),
            ("build", ["build.gradle", "build.gradle.kts"], .gradleBuildDirs),
            ("target", ["pom.xml"], .mavenTarget),  // same name as Rust, different marker
            ("vendor", ["composer.json"], .phpVendor),
            (".dart_tool", ["pubspec.yaml"], .flutterDartTool),
            (".next", ["package.json"], .jsBuildDirs),
            (".nuxt", ["package.json"], .jsBuildDirs),
            (".svelte-kit", ["package.json"], .jsBuildDirs),
            (".turbo", ["package.json"], .jsBuildDirs),
            (".output", ["package.json"], .jsBuildDirs),
        ]
        // Python cache dirs: always included (no marker needed).
        let pyAlwaysInclude: Set<String> = ["__pycache__", ".pytest_cache", ".tox", ".ipynb_checkpoints"]
        let venvMarkers = ["pyproject.toml", "requirements.txt", "setup.py"]
        let skipDirs: Set<String> = [".git", "node_modules", "target", "build", ".build", "DerivedData"]

        var results: [Category: [ScanItem]] = [:]
        let fm = FileManager.default

        for root in devRoots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
                ) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                let dirName = url.lastPathComponent
                if dirName == ".git" || enumerator.level > 12 {
                    enumerator.skipDescendants()
                    continue
                }

                // Check build-dir targets.
                var matched = false
                for (name, markers, cat) in buildTargets where dirName == name {
                    let parent = url.deletingLastPathComponent()
                    let hasMarker = markers.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
                    if hasMarker {
                        enumerator.skipDescendants()
                        results[cat, default: []].append(ScanItem(
                            url: url,
                            sizeBytes: DiskScanner.allocatedSize(of: url),
                            isDirectory: true,
                            category: cat,
                            detail: parent.lastPathComponent,
                            lastModified: values.contentModificationDate
                        ))
                        matched = true
                        break
                    } else if name == "node_modules" {
                        enumerator.skipDescendants()
                        matched = true
                        break
                    }
                }
                if matched { continue }

                // Python caches.
                if pyAlwaysInclude.contains(dirName) {
                    enumerator.skipDescendants()
                    results[.pythonCaches, default: []].append(ScanItem(
                        url: url,
                        sizeBytes: DiskScanner.allocatedSize(of: url),
                        isDirectory: true,
                        category: .pythonCaches,
                        detail: url.deletingLastPathComponent().lastPathComponent,
                        lastModified: values.contentModificationDate
                    ))
                    continue
                }
                if dirName == ".venv" {
                    let parent = url.deletingLastPathComponent()
                    let hasMarker = venvMarkers.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
                    if hasMarker {
                        enumerator.skipDescendants()
                        results[.pythonCaches, default: []].append(ScanItem(
                            url: url,
                            sizeBytes: DiskScanner.allocatedSize(of: url),
                            isDirectory: true,
                            category: .pythonCaches,
                            detail: parent.lastPathComponent,
                            lastModified: values.contentModificationDate
                        ))
                        continue
                    }
                }

                // Unity Library (gated on sibling ProjectSettings dir).
                if dirName == "Library" {
                    let parent = url.deletingLastPathComponent()
                    if fm.fileExists(atPath: parent.appending(path: "ProjectSettings").path) {
                        enumerator.skipDescendants()
                        results[.unityLibrary, default: []].append(ScanItem(
                            url: url,
                            sizeBytes: DiskScanner.allocatedSize(of: url),
                            isDirectory: true,
                            category: .unityLibrary,
                            detail: parent.lastPathComponent,
                            lastModified: values.contentModificationDate
                        ))
                    }
                }

                // Python caches skip dirs so it doesn't re-walk other categories' trees.
                if skipDirs.contains(dirName) {
                    enumerator.skipDescendants()
                }
            }
        }

        // Sort each category's items by size descending.
        for (cat, items) in results {
            results[cat] = items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
        return results
    }

    /// Finds build directories (node_modules, Rust target/, Pods/, .build/,
    /// Gradle build/) under the dev roots. One or more sibling marker files
    /// (package.json, Cargo.toml, Podfile, …) must exist so a random folder
    /// that happens to share the name isn't suggested. `category` labels the
    /// resulting items; `detail` carries the owning project name and
    /// `lastModified` the last build time so the user can judge activity.
    private func buildDirs(
        named name: String,
        siblingMarkers: [String],
        category: Category
    ) -> [ScanItem] {
        let fm = FileManager.default
        var results: [ScanItem] = []
        for root in devRoots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
                ) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                let dirName = url.lastPathComponent
                if dirName == ".git" || enumerator.level > 12 {
                    enumerator.skipDescendants()
                    continue
                }
                guard dirName == name else { continue }

                let parent = url.deletingLastPathComponent()
                let hasMarker = siblingMarkers.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
                if hasMarker {
                    enumerator.skipDescendants()
                    results.append(ScanItem(
                        url: url,
                        sizeBytes: DiskScanner.allocatedSize(of: url),
                        isDirectory: true,
                        category: category,
                        detail: parent.lastPathComponent,
                        lastModified: values.contentModificationDate
                    ))
                } else if name == "node_modules" {
                    // Not a real npm install dir, but still never worth walking.
                    enumerator.skipDescendants()
                }
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Python bytecode caches and virtualenvs under the dev roots.
    /// `__pycache__`, `.pytest_cache`, `.ipynb_checkpoints` are always included
    /// (regenerable, always safe). `.tox` is included too (regenerable via
    /// `tox`, but rebuilding runs the whole matrix — the category is
    /// suggest-only anyway). `.venv` is included only when a sibling project
    /// marker (`pyproject.toml`, `requirements.txt`, or `setup.py`) confirms
    /// it's a project virtualenv — a random `.venv` without one is left alone.
    /// Skips `.git`, `node_modules`, `target`, `build`, `.build`, `DerivedData`
    /// so it never re-walks trees other categories already surface.
    private func pythonCaches() -> [ScanItem] {
        let fm = FileManager.default
        let venvMarkers = ["pyproject.toml", "requirements.txt", "setup.py"]
        let alwaysInclude: Set<String> = ["__pycache__", ".pytest_cache", ".tox", ".ipynb_checkpoints"]
        let skipDirs: Set<String> = [".git", "node_modules", "target", "build", ".build", "DerivedData"]
        var results: [ScanItem] = []
        for root in devRoots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
                ) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                let dirName = url.lastPathComponent
                if skipDirs.contains(dirName) || enumerator.level > 12 {
                    enumerator.skipDescendants()
                    continue
                }

                if alwaysInclude.contains(dirName) {
                    results.append(ScanItem(
                        url: url,
                        sizeBytes: DiskScanner.allocatedSize(of: url),
                        isDirectory: true,
                        category: .pythonCaches,
                        detail: url.deletingLastPathComponent().lastPathComponent,
                        lastModified: values.contentModificationDate
                    ))
                    enumerator.skipDescendants()
                } else if dirName == ".venv" {
                    let parent = url.deletingLastPathComponent()
                    let hasMarker = venvMarkers.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
                    if hasMarker {
                        enumerator.skipDescendants()
                        results.append(ScanItem(
                            url: url,
                            sizeBytes: DiskScanner.allocatedSize(of: url),
                            isDirectory: true,
                            category: .pythonCaches,
                            detail: parent.lastPathComponent,
                            lastModified: values.contentModificationDate
                        ))
                    }
                }
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// JS framework build output dirs under the dev roots: `.next`, `.nuxt`,
    /// `.svelte-kit`, `.turbo`, `.output` — each with a sibling `package.json`
    /// so a coincidentally-named folder isn't suggested. Regenerable via the
    /// framework's build command. Concatenates `buildDirs` results across
    /// the dir names; all items are labeled `.jsBuildDirs`.
    private func jsBuildDirs() -> [ScanItem] {
        let names = [".next", ".nuxt", ".svelte-kit", ".turbo", ".output"]
        var items: [ScanItem] = []
        for name in names {
            items.append(contentsOf: buildDirs(
                named: name, siblingMarkers: ["package.json"], category: .jsBuildDirs))
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Per-app caches inside sandboxed app containers:
    /// `~/Library/Containers/<bundle-id>/Data/Library/Caches/<child>`. Surfaced
    /// per child (per-app granularity, mirroring how `userCaches` surfaces
    /// children of `~/Library/Caches`). Skips the Mail container — its cache
    /// is covered by `mailDownloads` — and skips the app's own container.
    private func containerCaches() async -> [ScanItem] {
        let root = home.appending(path: "Library/Containers")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let containers = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        // Scan all containers' caches in parallel — the old code scanned
        // each container sequentially, which was slow with many containers.
        let results = await withTaskGroup(of: [ScanItem].self) { group in
            for container in containers {
                let containerID = container.lastPathComponent
                if containerID == "com.apple.Mail" { continue }
                let cachesDir = container.appending(path: "Data/Library/Caches")
                group.addTask {
                    let items = await DiskScanner.topLevelScan(root: cachesDir, category: .containerCaches)
                    return items.map { item in
                        ScanItem(
                            url: item.url, sizeBytes: item.sizeBytes, isDirectory: item.isDirectory,
                            category: .containerCaches, detail: containerID,
                            lastModified: item.lastModified)
                    }
                }
            }
            var combined: [ScanItem] = []
            for await items in group { combined.append(contentsOf: items) }
            return combined
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Mail attachment cache: children of
    /// `~/Library/Containers/com.apple.Mail/Data/Library/Mail Downloads`.
    /// Mail re-downloads from the server, so trashing is safe.
    private func mailDownloads() async -> [ScanItem] {
        let dir = home.appending(path: "Library/Containers/com.apple.Mail/Data/Library/Mail Downloads")
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return await DiskScanner.topLevelScan(root: dir, category: .mailDownloads)
    }

    /// Xcode archives. Xcode nests these under a date folder
    /// (`Archives/2026-08-26/MyApp.xcarchive`), so this descends one level:
    /// any `.xcarchive` at the Archives root OR inside a date-named subdir is
    /// surfaced. Suggest-only — these hold symbols for past uploads.
    private func xcodeArchives() async -> [ScanItem] {
        let root = home.appending(path: "Library/Developer/Xcode/Archives")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var found: [ScanItem] = []
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        for entry in entries {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                if entry.lastPathComponent.hasSuffix(".xcarchive") {
                    // Archive at the root.
                    let size = await Task.detached { DiskScanner.allocatedSize(of: entry) }.value
                    if size > 0 {
                        found.append(ScanItem(url: entry, sizeBytes: size, isDirectory: true,
                                             category: .xcodeArchives))
                    }
                } else {
                    // Date-named subdir — descend one level for .xcarchive bundles.
                    let sub = await DiskScanner.topLevelScan(root: entry, category: .xcodeArchives)
                    for item in sub where item.url.lastPathComponent.hasSuffix(".xcarchive") {
                        found.append(item)
                    }
                }
            }
        }
        return found.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Unity's imported-asset cache: a `Library/` dir under a Unity project,
    /// gated on a sibling `ProjectSettings/` dir (the reliable Unity-project
    /// signal — `Assets/` alone is too generic). Suggest-only: rebuilding
    /// re-imports every asset, which can be slow.
    private func unityLibrary() -> [ScanItem] {
        let fm = FileManager.default
        var results: [ScanItem] = []
        for root in devRoots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
                ) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                let dirName = url.lastPathComponent
                if dirName == ".git" || enumerator.level > 12 {
                    enumerator.skipDescendants()
                    continue
                }
                guard dirName == "Library" else { continue }
                let parent = url.deletingLastPathComponent()
                // Gate on a sibling ProjectSettings dir — the reliable marker
                // that this folder belongs to a Unity project (not a random
                // folder named "Library").
                guard fm.fileExists(atPath: parent.appending(path: "ProjectSettings").path) else {
                    enumerator.skipDescendants()
                    continue
                }
                enumerator.skipDescendants()
                results.append(ScanItem(
                    url: url,
                    sizeBytes: DiskScanner.allocatedSize(of: url),
                    isDirectory: true,
                    category: .unityLibrary,
                    detail: parent.lastPathComponent,
                    lastModified: values.contentModificationDate
                ))
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Downloaded Android SDK system images:
    /// `~/Library/Android/sdk/system-images/<abi>/<api>/<variant>`. Surfaced
    /// at the leaf-variant granularity (the actual reclaimable unit), each is
    /// needed by a specific AVD so the category is suggest-only.
    private func androidSystemImages() async -> [ScanItem] {
        let root = home.appending(path: "Library/Android/sdk/system-images")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        // The tree is abi/api/variant — three levels deep. Surface the
        // variant-level dirs (the leaves a user would delete individually).
        let fm = FileManager.default
        var found: [ScanItem] = []
        guard let abis = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        for abi in abis where (try? abi.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let apis = try? fm.contentsOfDirectory(
                at: abi, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for api in apis where (try? api.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let items = await DiskScanner.topLevelScan(root: api, category: .androidSystemImages)
                for item in items where item.isDirectory {
                    found.append(ScanItem(
                        url: item.url,
                        sizeBytes: item.sizeBytes,
                        isDirectory: true,
                        category: .androidSystemImages,
                        detail: "\(abi.lastPathComponent)/\(api.lastPathComponent)/\(item.url.lastPathComponent)",
                        lastModified: item.lastModified
                    ))
                }
            }
        }
        return found.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Screenshot files on the Desktop older than 30 days. macOS names them
    /// "Screenshot ..." or "Screen Shot ...". Suggest-only: these are user
    /// files, not regenerable. Mirrors `oldInstallers`'s age-gated
    /// `contentsOfDirectory` approach.
    private func staleScreenshots() -> [ScanItem] {
        let desktop = home.appending(path: "Desktop")
        let cutoff = Date.now.addingTimeInterval(-30 * 86400)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: desktop, includingPropertiesForKeys: Array(keys)
        ) else { return [] }
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ") else { return nil }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff else { return nil }
            return ScanItem(url: url, sizeBytes: Int64(values.totalFileAllocatedSize ?? 0),
                            isDirectory: false, category: .staleScreenshots,
                            lastModified: modified)
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }
}

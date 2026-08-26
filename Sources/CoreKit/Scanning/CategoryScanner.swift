import Foundation

public struct CategoryResult: Identifiable, Sendable, Codable {
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
        await withTaskGroup(of: CategoryResult.self) { group in
            for category in Category.allCases {
                if Task.isCancelled { break }
                group.addTask {
                    if Task.isCancelled { return CategoryResult(category: category, items: []) }
                    progress?(category)
                    return await scan(category)
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
            items = buildDirs(named: "node_modules", siblingMarkers: ["package.json"], category: .nodeModules)
        case .rustTargets:
            items = buildDirs(named: "target", siblingMarkers: ["Cargo.toml"], category: .rustTargets)
        case .podDirs:
            items = buildDirs(named: "Pods", siblingMarkers: ["Podfile"], category: .podDirs)
        case .swiftBuildDirs:
            items = buildDirs(named: ".build", siblingMarkers: ["Package.swift"], category: .swiftBuildDirs)
        case .gradleBuildDirs:
            items = buildDirs(named: "build", siblingMarkers: ["build.gradle", "build.gradle.kts"], category: .gradleBuildDirs)
        case .pythonCaches:
            items = pythonCaches()
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
            ("Library/pnpm/store", "pnpm store"),
            ("go/pkg/mod", "Go module cache"),
            (".m2/repository", "Maven repository"),
            (".yarn/cache", "Yarn cache"),
            (".terraform.d/plugin-cache", "Terraform plugin cache"),
            // Bun package cache (home-rooted; not under ~/Library/Caches so
            // no overlap with the userCaches category).
            (".bun/install/cache", "Bun cache"),
            // XDG cache dir — pip, mypy, pytest, pre-commit, httpie, etc. all
            // live under here. Counted once at the root so we don't double-
            // count its children individually.
            (".cache", "XDG cache (~/.cache)"),
            // Deno's cache directory (home-rooted variant; the
            // ~/Library/Caches/deno location, if present, is covered by
            // userCaches).
            (".deno", "Deno cache"),
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
    /// `__pycache__` is always included (regenerable, always safe). `.venv` is
    /// included only when a sibling project marker (`pyproject.toml`,
    /// `requirements.txt`, or `setup.py`) confirms it's a project virtualenv —
    /// a random `.venv` without one is left alone. Skips `.git`, `node_modules`,
    /// `target`, `build`, `.build`, `DerivedData` so it never re-walks trees
    /// other categories already surface.
    private func pythonCaches() -> [ScanItem] {
        let fm = FileManager.default
        let venvMarkers = ["pyproject.toml", "requirements.txt", "setup.py"]
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

                if dirName == "__pycache__" {
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
}

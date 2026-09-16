import Foundation

extension CategoryScanner {
    func children(of relativePath: String, _ category: Category) async -> [ScanItem] {
        await DiskScanner.topLevelScan(root: home.appending(path: relativePath), category: category)
    }

    func wholeDir(_ url: URL, _ category: Category) -> [ScanItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = DiskScanner.allocatedSize(of: url)
        guard size > 0 else { return [] }
        return [ScanItem(url: url, sizeBytes: size, isDirectory: true, category: category)]
    }

    func homebrewCache() -> [ScanItem] {
        guard let brew = Shell.find("brew"),
              let output = Shell.run(brew, ["--cache"]), output.succeeded else { return [] }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return [] }
        return wholeDir(URL(fileURLWithPath: path), .homebrewCache)
    }

    func oldInstallers() -> [ScanItem] {
        let roots = [
            home.appending(path: "Downloads"),
            home.appending(path: "Desktop"),
        ]
        let cutoff = Date.now.addingTimeInterval(-Double(installerMinAgeDays) * 86400)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        let extensions: Set<String> = ["dmg", "pkg", "xip", "iso"]
        var seen = Set<String>()
        var results: [ScanItem] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: Array(keys)
            ) else { continue }
            for url in entries {
                let canonical = url.resolvingSymlinksInPath().path
                guard !seen.contains(canonical),
                      extensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified < cutoff
                else { continue }
                seen.insert(canonical)
                results.append(ScanItem(url: url, sizeBytes: Int64(values.totalFileAllocatedSize ?? 0),
                                        isDirectory: false, category: .oldInstallers,
                                        lastModified: modified))
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Local device backups made by Finder syncing. Each backup folder's
    /// Info.plist carries the device name and last-backup date so the user
    /// can tell a stale backup from tonight's.
    func iosBackups() async -> [ScanItem] {
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
    func devCaches() async -> [ScanItem] {
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
            for await case let item? in group {
                items.append(item)
            }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    /// Largest per-app data folders in ~/Library/Application Support. These
    /// hold real app state, so the category is suggest-only — the user must
    /// judge each one. Apple's own subfolders are listed too (for awareness)
    /// but trashing them is rarely safe; the SafePathPolicy still allows
    /// trashing arbitrary subfolders here, so the explanation warns loudly.
    func appSupportHoarders() async -> [ScanItem] {
        let root = home.appending(path: "Library/Application Support")
        let items = await DiskScanner.topLevelScan(root: root, category: .appSupport)
        // Surface the top 30 by size — there can be dozens of tiny ones.
        return Array(items.prefix(30))
    }

    /// Largest individual files under the user's Downloads and dev roots.
    /// Library is excluded so this doesn't overlap the dedicated Library
    /// categories (caches, backups, Application Support, …). Build/VCS trees
    /// are skipped inside `largeFiles` for the same reason. Suggest-only.
    func bigFiles() async -> [ScanItem] {
        let roots = [home.appending(path: "Downloads")] + devRoots
        return await Task.detached {
            DiskScanner.largeFiles(under: roots, minSize: 100 * 1024 * 1024)
        }.value
    }

    /// Per-app caches inside sandboxed app containers:
    /// `~/Library/Containers/<bundle-id>/Data/Library/Caches/<child>`. Surfaced
    /// per child (per-app granularity, mirroring how `userCaches` surfaces
    /// children of `~/Library/Caches`). Skips the Mail container — its cache
    /// is covered by `mailDownloads` — and skips the app's own container.
    func containerCaches() async -> [ScanItem] {
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
    func mailDownloads() async -> [ScanItem] {
        let dir = home.appending(path: "Library/Containers/com.apple.Mail/Data/Library/Mail Downloads")
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return await DiskScanner.topLevelScan(root: dir, category: .mailDownloads)
    }

    /// Xcode archives. Xcode nests these under a date folder
    /// (`Archives/2026-08-26/MyApp.xcarchive`), so this descends one level:
    /// any `.xcarchive` at the Archives root OR inside a date-named subdir is
    /// surfaced. Suggest-only — these hold symbols for past uploads.
    func xcodeArchives() async -> [ScanItem] {
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

    /// Downloaded Android SDK system images:
    /// `~/Library/Android/sdk/system-images/<abi>/<api>/<variant>`. Surfaced
    /// at the leaf-variant granularity (the actual reclaimable unit), each is
    /// needed by a specific AVD so the category is suggest-only.
    func androidSystemImages() async -> [ScanItem] {
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
    func staleScreenshots() -> [ScanItem] {
        let desktop = home.appending(path: "Desktop")
        let cutoff = Date.now.addingTimeInterval(-Double(screenshotMinAgeDays) * 86400)
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

import Foundation

/// Finds what can go inside ~/Library/Application Support: Chromium and
/// Electron caches in any app's folder, the folders `AppSupportRules` names,
/// versions kept beside a newer one, virtual machine disks, and whole folders
/// of apps that are no longer installed. Never lists the folder of an
/// installed app wholesale. Read-only.
enum AppSupportScanner {
    /// Smaller items aren't worth a row (every Electron app has a few
    /// kilobytes of shader cache).
    static let minimumBytes: Int64 = 1 << 20

    /// Inside an app's folder, look this many levels down: deep enough for
    /// `Google/Chrome/Default/Service Worker`, bounded so a folder with a
    /// huge tree (game files) costs little.
    static let maxDepth = 3
    static let maxDirectoriesPerOwner = 3000

    /// Never descended: big data trees that hold no caches of their own.
    static let skipDescending: Set<String> = [
        "steamapps", "node_modules", ".git", "IndexedDB", "Local Storage",
        "Session Storage", "File System", "databases", "Extensions",
        "vm_bundles", "blob_storage", "WebStorage",
    ]

    /// A folder of a removed app must also be this old: a background tool
    /// with no app of its own keeps writing to its folder, a leftover doesn't.
    static let leftoverMinimumAge: TimeInterval = 30 * 86_400

    /// Virtual machine disks: image files this big, and machine bundles.
    static let virtualDiskMinimumBytes: Int64 = 1 << 30
    static let diskImageExtensions: Set<String> = ["img", "raw", "qcow2", "vmdk", "vdi", "hdd", "hds"]
    static let machineBundleExtensions: Set<String> = ["utm", "pvm", "vmwarevm", "sparsebundle"]

    typealias Candidate = (url: URL, finding: AppSupportRules.Finding?)

    static func items(in root: URL, installed: InstalledApps, now: Date = Date()) -> [ScanItem] {
        let fm = FileManager.default
        guard let owners = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return [] }

        var candidates: [Candidate] = []
        for owner in owners where isRealDirectory(owner) {
            if Task.isCancelled { return [] }
            guard !AppSupportRules.skippedOwners.contains(owner.lastPathComponent) else { continue }
            if isLeftover(owner, installed: installed, now: now) {
                candidates.append((owner, .leftover))
                continue
            }
            candidates += namedCandidates(in: owner).map { ($0, nil) }
            candidates += walk(owner)
        }

        // The first candidate for a path wins, so a named rule beats a
        // generic finding for the same folder.
        var findings: [String: AppSupportRules.Finding] = [:]
        var seen = Set<String>()
        var urls: [URL] = []
        for candidate in candidates {
            let path = candidate.url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            urls.append(candidate.url)
            if let finding = candidate.finding { findings[path] = finding }
        }

        // One owner per byte: what's handled elsewhere is listed there, not
        // here as well (a Multipass disk image, say).
        let home = root.deletingLastPathComponent().deletingLastPathComponent()
        let unique = outermost(urls).filter { HandledElsewhere.rule(covering: $0, home: home) == nil }
        let directories = unique.filter(isRealDirectory)
        let directorySizes = Dictionary(uniqueKeysWithValues: zip(
            directories.map(\.path), BulkWalker.allocatedSizes(of: directories.map(\.path))))
        var items: [ScanItem] = []
        for url in unique {
            let directorySize = directorySizes[url.path]
            let size = directorySize ?? fileSize(url)
            guard size >= minimumBytes else { continue }
            let finding = findings[url.path]?.rawValue
            let draft = ScanItem(url: url, sizeBytes: size, isDirectory: directorySize != nil,
                                 category: .appSupport, finding: finding)
            guard let insight = AppSupportRules.insight(for: draft) else { continue }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            items.append(ScanItem(url: url, sizeBytes: size, isDirectory: directorySize != nil,
                                  category: .appSupport, detail: insight.owner,
                                  lastModified: modified, finding: finding))
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// A folder named like an app's bundle identifier, with no installed app
    /// owning it, untouched for a month. Apple's folders are skipped: most
    /// belong to background services that have no app at all.
    static func isLeftover(_ owner: URL, installed: InstalledApps, now: Date) -> Bool {
        let name = owner.lastPathComponent
        guard AppSupportRules.isBundleIdentifier(name),
              !name.lowercased().hasPrefix("com.apple."),
              AppSupportRules.ownerBundleIDs[name] == nil,
              !AppSupportRules.named.contains(where: { $0.owner == name }),
              let modified = newestModification(of: owner),
              now.timeIntervalSince(modified) >= leftoverMinimumAge
        else { return false }
        return !installed.owns(name)
    }

    /// The folder's own date or its newest direct child's: writing a file
    /// updates the file, not the folder above it.
    static func newestModification(of folder: URL) -> Date? {
        let key: URLResourceKey = .contentModificationDateKey
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [key])) ?? []
        return ([folder] + children)
            .compactMap { try? $0.resourceValues(forKeys: [key]).contentModificationDate }
            .max()
    }

    static func namedCandidates(in owner: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for rule in AppSupportRules.named where rule.owner == owner.lastPathComponent {
            let target = rule.path.isEmpty ? owner : owner.appending(path: rule.path)
            guard isRealDirectory(target) else { continue }
            switch rule.kind {
            case .whole:
                found.append(target)
            case .supersededVersions:
                let versions = ((try? fm.contentsOfDirectory(
                    at: target, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )) ?? [])
                    .filter { isRealDirectory($0) && AppSupportRules.isVersion($0.lastPathComponent) }
                    .sorted { UpdateChecker.Version($0.lastPathComponent) < UpdateChecker.Version($1.lastPathComponent) }
                found += versions.dropLast()
            }
        }
        return found
    }

    /// Breadth-first over directories below `owner`. A cache folder counts
    /// only where its siblings show a Chromium profile or Electron app root;
    /// dotted versions count when they make up most of their folder.
    static func walk(_ owner: URL) -> [Candidate] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey]
        var found: [Candidate] = []
        var queue: [(url: URL, depth: Int)] = [(owner, 0)]
        var next = 0
        while next < queue.count, next < maxDirectoriesPerOwner {
            let (directory, depth) = queue[next]
            next += 1
            guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
                continue
            }
            let names = Set(children.map(\.lastPathComponent))
            let isChromium = !names.isDisjoint(with: AppSupportRules.chromiumMarkers)

            let subdirectories = children.filter(isRealDirectory)
            let versions = subdirectories.filter { AppSupportRules.isDottedVersion($0.lastPathComponent) }
            var older = Set<URL>()
            if versions.count >= 2, versions.count * 2 >= subdirectories.count {
                let sorted = versions.sorted {
                    UpdateChecker.Version($0.lastPathComponent) < UpdateChecker.Version($1.lastPathComponent)
                }
                for version in sorted.dropLast() {
                    found.append((version, .olderVersion))
                    older.insert(version)
                }
            }

            for child in children {
                let name = child.lastPathComponent
                let ext = child.pathExtension.lowercased()
                if isRealDirectory(child) {
                    if older.contains(child) { continue }
                    if machineBundleExtensions.contains(ext) {
                        found.append((child, .virtualDisk))
                    } else if isChromium, AppSupportRules.chromiumCaches[name] != nil {
                        found.append((child, nil))
                    } else if isChromium, name == "Service Worker" {
                        let storage = child.appending(path: "CacheStorage")
                        if isRealDirectory(storage) { found.append((storage, nil)) }
                    } else if depth + 1 <= maxDepth, !skipDescending.contains(name) {
                        queue.append((child, depth + 1))
                    }
                } else if diskImageExtensions.contains(ext), fileSize(child) >= virtualDiskMinimumBytes {
                    found.append((child, .virtualDisk))
                }
            }
        }
        return found
    }

    static func fileSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
              values.isRegularFile == true else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? 0)
    }

    /// Drops duplicates and anything inside another candidate, so no byte is
    /// listed twice.
    static func outermost(_ urls: [URL]) -> [URL] {
        let sorted = Set(urls.map(\.standardizedFileURL)).sorted { $0.path < $1.path }
        var kept: [URL] = []
        for url in sorted {
            if let last = kept.last, url.path.hasPrefix(last.path + "/") { continue }
            kept.append(url)
        }
        return kept
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

extension CategoryScanner {
    func appSupportItems() async -> [ScanItem] {
        let root = home.appending(path: AppSupportRules.root)
        let home = home
        let installed = installedApps
        return await Task.detached(priority: .userInitiated) {
            AppSupportScanner.items(in: root, installed: installed ?? InstalledApps.scan(home: home))
        }.value
    }
}

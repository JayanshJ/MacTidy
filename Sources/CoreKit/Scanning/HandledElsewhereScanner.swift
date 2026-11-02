import Foundation

/// Finds and sizes what `HandledElsewhere` names. Looks only at those paths;
/// a wildcard reads the one folder it sits in, nothing wider. Unreadable or
/// missing paths produce no row and no error. Read-only.
enum HandledElsewhereScanner {
    /// Only big things are worth pointing out.
    static let minimumBytes: Int64 = 100_000_000

    /// Rules behind macOS privacy checks are skipped without Full Disk Access,
    /// so a scan in limited mode can't raise a prompt for them.
    static func items(home: URL, fullDiskAccess: Bool, minimumBytes: Int64 = minimumBytes) -> [ScanItem] {
        var targets: [(url: URL, rule: ElsewhereRule)] = []
        for rule in HandledElsewhere.rules where fullDiskAccess || !rule.needsFullDiskAccess {
            targets += expand(rule.components, from: home).map { ($0, rule) }
        }

        let directories = targets.map(\.url).filter(AppSupportScanner.isRealDirectory)
        // Never downloads anything: iCloud files and folders that aren't on
        // this Mac count as nothing, which is what they take up.
        let sizes = Dictionary(uniqueKeysWithValues: zip(
            directories.map(\.path),
            BulkWalker.allocatedSizes(of: directories.map(\.path), materializingDataless: false)))

        var items: [ScanItem] = []
        for (url, rule) in targets {
            let directorySize = sizes[url.path]
            let size = directorySize ?? AppSupportScanner.fileSize(url)
            guard size >= minimumBytes else { continue }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            // No category: this is what keeps it out of every total.
            items.append(ScanItem(url: url, sizeBytes: size, isDirectory: directorySize != nil,
                                  detail: rule.owner, lastModified: modified, finding: rule.id))
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// The existing paths a pattern names. Links aren't followed at the
    /// wildcards or at the end, so a link can't pull in another tree.
    static func expand(_ components: [String], from home: URL) -> [URL] {
        let fm = FileManager.default
        var current = [home]
        for component in components {
            if component.contains("*") {
                current = current.flatMap { folder -> [URL] in
                    let children = (try? fm.contentsOfDirectory(
                        at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
                    return children.filter {
                        HandledElsewhere.componentMatches($0.lastPathComponent, component) && !isSymlink($0)
                    }
                }
            } else {
                current = current.map { $0.appending(path: component) }
            }
        }
        return current.filter { fm.fileExists(atPath: $0.path) && !isSymlink($0) }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}

extension CategoryScanner {
    /// What's on this Mac that another app or setting manages. Deliberately
    /// not a category and not part of `scanAll`, so none of it can be counted
    /// as reclaimable.
    public func handledElsewhereItems(fullDiskAccess: Bool) async -> [ScanItem] {
        await handledElsewhereItems(fullDiskAccess: fullDiskAccess, minimumBytes: HandledElsewhereScanner.minimumBytes)
    }

    /// Runs in the caller's task, so cancelling a scan stops the walk.
    func handledElsewhereItems(fullDiskAccess: Bool, minimumBytes: Int64) async -> [ScanItem] {
        HandledElsewhereScanner.items(home: home, fullDiskAccess: fullDiskAccess, minimumBytes: minimumBytes)
            .filter { !ignore.contains($0.url) }
    }
}

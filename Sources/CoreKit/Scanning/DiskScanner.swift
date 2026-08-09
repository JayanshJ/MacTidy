import Foundation

public struct ScanProgress: Sendable {
    public let currentPath: String
    public let scannedBytes: Int64
}

/// The shared read-only scanning engine. Sizes are `.totalFileAllocatedSize`
/// (actual on-disk blocks, what Finder and `du` report), never logical size.
/// Scanning never mutates the filesystem.
public enum DiskScanner {
    /// Recursive allocated size of a file or directory tree. Unreadable
    /// entries are skipped (there are many even with Full Disk Access).
    /// Symlinks are not followed, so trees can't be double-counted and the
    /// scan can't escape the root.
    public static func allocatedSize(
        of root: URL,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? root.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
           values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [], // include hidden files; ~/Library dotfiles count too
            errorHandler: { _, _ in true } // keep scanning past unreadable paths
        ) else { return 0 }

        var total: Int64 = 0
        var seen = 0
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
            seen += 1
            if seen % 512 == 0 {
                progress?(ScanProgress(currentPath: url.path, scannedBytes: total))
            }
        }
        return total
    }

    /// Sizes the immediate children of `root` concurrently (one task per
    /// child), returning them largest-first. This powers the
    /// "where did my space go" explorer.
    public static func topLevelScan(
        root: URL,
        category: Category? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> [ScanItem] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
        ]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys)
        ) else { return [] }

        return await withTaskGroup(of: ScanItem?.self) { group in
            for child in children {
                group.addTask {
                    guard let values = try? child.resourceValues(forKeys: keys),
                          values.isSymbolicLink != true else { return nil }
                    let modified = values.contentModificationDate
                    if values.isDirectory == true {
                        let size = allocatedSize(of: child, progress: progress)
                        return ScanItem(url: child, sizeBytes: size, isDirectory: true,
                                        category: category, lastModified: modified)
                    }
                    return ScanItem(url: child,
                                    sizeBytes: Int64(values.totalFileAllocatedSize ?? 0),
                                    isDirectory: false, category: category,
                                    lastModified: modified)
                }
            }
            var items: [ScanItem] = []
            for await item in group where item != nil {
                items.append(item!)
            }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    /// Recursively finds the largest regular files under `roots`, returning the
    /// top results largest-first. Symlinks are not followed (a tree can't be
    /// double-counted and the walk can't escape the root). Powers the
    /// suggest-only "Large files" category. Capped so a huge home directory
    /// can't produce an unbounded list.
    public static func largeFiles(
        under roots: [URL],
        minSize: Int64 = 100 * 1024 * 1024,
        maxResults: Int = 250,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) -> [ScanItem] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .contentModificationDateKey,
        ]
        var found: [ScanItem] = []
        let fm = FileManager.default

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            // Don't descend into build/VCS trees — their contents are already
            // surfaced by the node_modules / Rust target / DerivedData
            // categories, and skipping them keeps this list from overlapping.
            let skipDirs: Set<String> = [
                ".git", "node_modules", "target", "build", ".build",
                ".venv", "DerivedData", "__pycache__",
            ]
            var seen = 0
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                if url.hasDirectoryPath,
                   skipDirs.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? 0)
                if size >= minSize {
                    found.append(ScanItem(
                        url: url,
                        sizeBytes: size,
                        isDirectory: false,
                        category: .bigFiles,
                        lastModified: values.contentModificationDate
                    ))
                }
                seen += 1
                if seen % 1024 == 0 { progress?(ScanProgress(currentPath: url.path, scannedBytes: 0)) }
            }
        }
        found.sort { $0.sizeBytes > $1.sizeBytes }
        return Array(found.prefix(maxResults))
    }
}

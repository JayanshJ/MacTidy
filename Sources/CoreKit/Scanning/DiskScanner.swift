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
    ///
    /// Walks with `getattrlistbulk(2)` on several threads (see `BulkWalker`),
    /// several times faster than a `FileManager` enumerator that stats every
    /// entry separately. Hidden files are included (AppleDouble `._` files
    /// too, as `du` counts them).
    public static func allocatedSize(
        of root: URL,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) -> Int64 {
        if let values = try? root.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
           values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        return BulkWalker.allocatedSizes(of: [root.path], progress: walkerProgress(progress))[0]
    }

    private static func walkerProgress(
        _ progress: (@Sendable (ScanProgress) -> Void)?
    ) -> (@Sendable (String, Int64) -> Void)? {
        guard let progress else { return nil }
        return { directory, bytes in progress(ScanProgress(currentPath: directory, scannedBytes: bytes)) }
    }

    /// Sizes the immediate children of `root`, returning them largest-first.
    /// All child directories are sized in one shared parallel walk, so one
    /// huge child doesn't leave the other cores idle. This powers the
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

        var items: [ScanItem] = []
        var directories: [(url: URL, modified: Date?)] = []
        for child in children {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                directories.append((child, values.contentModificationDate))
            } else {
                items.append(ScanItem(url: child,
                                      sizeBytes: Int64(values.totalFileAllocatedSize ?? 0),
                                      isDirectory: false, category: category,
                                      lastModified: values.contentModificationDate))
            }
        }
        let sizes = BulkWalker.allocatedSizes(
            of: directories.map(\.url.path), progress: walkerProgress(progress))
        for (directory, size) in zip(directories, sizes) {
            items.append(ScanItem(url: directory.url, sizeBytes: size, isDirectory: true,
                                  category: category, lastModified: directory.modified))
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
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
                ".venv", "DerivedData", "__pycache__", "Pods",
                ".next", ".nuxt", ".svelte-kit", ".turbo", ".output",
                ".dart_tool", ".pytest_cache", ".tox", ".ipynb_checkpoints",
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

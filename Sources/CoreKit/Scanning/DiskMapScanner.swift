import Foundation

/// Session-only estimates. Directory modification dates do not track changes deep
/// in a tree, so entries also expire; a manual refresh can invalidate them.
public final class DiskMapSizeCache: @unchecked Sendable {
    private struct Entry { let size: Int64; let modified: Date?; let stored: Date }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    public let lifetime: TimeInterval
    public init(lifetime: TimeInterval = 30) { self.lifetime = lifetime }
    public func size(for url: URL, modified: Date?, now: Date = Date()) -> Int64? {
        lock.withLock {
            guard let entry = entries[url.standardizedFileURL.path], entry.modified == modified,
                  now.timeIntervalSince(entry.stored) >= 0,
                  now.timeIntervalSince(entry.stored) < lifetime else { return nil }
            return entry.size
        }
    }
    public func store(_ size: Int64, for url: URL, modified: Date?, now: Date = Date()) {
        lock.withLock { entries[url.standardizedFileURL.path] = Entry(size: size, modified: modified, stored: now) }
    }
    public func invalidate() { lock.withLock { entries.removeAll() } }
}

public enum DiskMapScanner {
    /// Emits files and each directory as soon as its walk finishes. The stream
    /// owns its worker so leaving the screen cancels all outstanding walks.
    public static func scan(root: URL, cache: DiskMapSizeCache) -> AsyncStream<ScanItem> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
                guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else {
                    continuation.finish(); return
                }
                var pending: [(URL, Date?)] = []
                for child in children {
                    if Task.isCancelled { break }
                    guard let values = try? child.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                    if values.isDirectory == true {
                        if let size = cache.size(for: child, modified: values.contentModificationDate) {
                            continuation.yield(ScanItem(url: child, sizeBytes: size, isDirectory: true, lastModified: values.contentModificationDate))
                        } else { pending.append((child, values.contentModificationDate)) }
                    } else {
                        continuation.yield(ScanItem(url: child, sizeBytes: Int64(values.totalFileAllocatedSize ?? 0), isDirectory: false, lastModified: values.contentModificationDate))
                    }
                }
                await withTaskGroup(of: ScanItem?.self) { group in
                    var index = 0
                    func submit() {
                        guard index < pending.count, !Task.isCancelled else { return }
                        let (url, modified) = pending[index]; index += 1
                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            let size = BulkWalker.allocatedSizes(of: [url.path], materializingDataless: false)[0]
                            guard !Task.isCancelled else { return nil }
                            cache.store(size, for: url, modified: modified)
                            return ScanItem(url: url, sizeBytes: size, isDirectory: true, lastModified: modified)
                        }
                    }
                    for _ in 0..<min(4, pending.count) { submit() }
                    while let result = await group.next() {
                        if Task.isCancelled { group.cancelAll(); break }
                        if let result { continuation.yield(result) }
                        submit()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}

public enum DiskMapDetails {
    /// Immediate children, including hidden entries; nil means unavailable.
    public static func childCount(at url: URL) -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: url.path).count
    }
}

public struct DiskMapFilter: Sendable {
    public enum Kind: Sendable { case all, files, folders }
    public var kind: Kind
    public var minimumBytes: Int64
    public var modifiedBefore: Date?
    public init(kind: Kind = .all, minimumBytes: Int64 = 0, modifiedBefore: Date? = nil) {
        self.kind = kind; self.minimumBytes = minimumBytes; self.modifiedBefore = modifiedBefore
    }
    public func matches(_ item: ScanItem) -> Bool {
        if kind == .files && item.isDirectory { return false }
        if kind == .folders && !item.isDirectory { return false }
        if item.sizeBytes < minimumBytes { return false }
        if let before = modifiedBefore {
            guard let modified = item.lastModified, modified <= before else { return false }
        }
        return true
    }
}

public enum DiskMapSearch {
    /// Recursive name search, including hidden entries, without following links
    /// or downloading iCloud content. Cancellation stops enumeration and sizing.
    public static func search(root: URL, name: String, cache: DiskMapSizeCache) -> AsyncStream<ScanItem> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { continuation.finish(); return }
                BulkWalker.withoutMaterializingDataless {
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
                    guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return }
                    while !Task.isCancelled, let url = iterator.nextObject() as? URL {
                        guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                        if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                        guard url.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
                        let directory = values.isDirectory == true
                        let modified = values.contentModificationDate
                        let size: Int64
                        if directory {
                            if let cached = cache.size(for: url, modified: modified) { size = cached }
                            else {
                                size = BulkWalker.allocatedSizes(of: [url.path], materializingDataless: false)[0]
                                if !Task.isCancelled { cache.store(size, for: url, modified: modified) }
                            }
                        } else { size = Int64(values.totalFileAllocatedSize ?? 0) }
                        if !Task.isCancelled { continuation.yield(ScanItem(url: url, sizeBytes: size, isDirectory: directory, lastModified: modified)) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum DiskMapSelection {
    public static func isEligible(_ item: ScanItem, extraRoots: [URL] = []) -> Bool {
        guard !HandledElsewhere.overlapsManagedLocation(item.url) else { return false }
        if case .failure = SafePathPolicy(extraAllowedRoots: extraRoots).classify(item.url) { return false }
        return true
    }
    /// Avoid overlapping candidates and double-counted bytes when selecting
    /// across folders or recursive search results.
    public static func adding(_ item: ScanItem, to selected: [ScanItem]) -> [ScanItem] {
        let path = item.url.standardizedFileURL.path
        if selected.contains(where: { path == $0.url.standardizedFileURL.path || path.hasPrefix($0.url.standardizedFileURL.path + "/") }) { return selected }
        return selected.filter { !$0.url.standardizedFileURL.path.hasPrefix(path + "/") } + [item]
    }
}

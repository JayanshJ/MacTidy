import CryptoKit
import Darwin
import Foundation

public struct DuplicateSet: Identifiable, Sendable {
    /// SHA-256 digest (hex) shared by every file in the set.
    public let id: String
    /// Files grouped by physical storage: members of one inner array already
    /// share their on-disk blocks (APFS clones or hardlinks), so they waste
    /// nothing relative to each other. Only extra *groups* waste space —
    /// reporting cloned copies as reclaimable would be dishonest.
    public let physicalGroups: [[ScanItem]]
    public let fileSizeBytes: Int64

    /// All copies, sorted by path. The user picks which to keep; the finder
    /// never auto-selects a survivor.
    public var files: [ScanItem] { physicalGroups.flatMap { $0 } }
    public var wastedBytes: Int64 {
        fileSizeBytes * Int64(max(physicalGroups.count - 1, 0))
    }
    /// Copies that already share storage with another copy in the set.
    public var alreadySharedCount: Int {
        physicalGroups.reduce(0) { $0 + max($1.count - 1, 0) }
    }
}

/// Content-equality duplicate finder over user-selected folders only.
/// Three-stage pipeline so almost nothing gets fully hashed:
/// size grouping → first-4KB partial hash → full SHA-256.
public enum DuplicateFinder {
    public static func find(
        in roots: [URL],
        minFileSize: Int64 = 1,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> [DuplicateSet] {
        // Stage 1: group by exact logical size; unique sizes can't be dupes.
        progress?("Listing files…")
        var bySize: [Int64: [URL]] = [:]
        for root in roots {
            for (url, size) in regularFiles(under: root) where size >= minFileSize {
                bySize[size, default: []].append(url)
            }
        }
        let sizeGroups = bySize.filter { $0.value.count > 1 }

        // Stages 2 + 3 per size group, groups hashed concurrently.
        return await withTaskGroup(of: [DuplicateSet].self) { group in
            for (size, urls) in sizeGroups {
                group.addTask {
                    progress?("Comparing \(urls.count) files of \(size.formattedBytes)…")
                    return resolveGroup(urls: urls, size: size)
                }
            }
            var sets: [DuplicateSet] = []
            for await partial in group { sets.append(contentsOf: partial) }
            return sets.sorted { $0.wastedBytes > $1.wastedBytes }
        }
    }

    private static func regularFiles(under root: URL) -> [(URL, Int64)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [(URL, Int64)] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            files.append((url, Int64(size)))
        }
        return files
    }

    private static func resolveGroup(urls: [URL], size: Int64) -> [DuplicateSet] {
        // Stage 2: partial hash of the first 4 KB.
        var byPartial: [String: [URL]] = [:]
        for url in urls {
            guard let digest = hash(url, limitBytes: 4096) else { continue }
            byPartial[digest, default: []].append(url)
        }

        // Stage 3: full hash of survivors.
        var byFull: [String: [URL]] = [:]
        for candidates in byPartial.values where candidates.count > 1 {
            for url in candidates {
                guard let digest = hash(url, limitBytes: nil) else { continue }
                byFull[digest, default: []].append(url)
            }
        }

        return byFull.compactMap { digest, members in
            guard members.count > 1 else { return nil }
            let groups = physicalGroups(of: members.sorted { $0.path < $1.path }, size: size)
            return DuplicateSet(id: digest, physicalGroups: groups, fileSizeBytes: size)
        }
    }

    /// Buckets identical files by their physical storage so clones and
    /// hardlinks are recognized as already-deduplicated.
    private static func physicalGroups(of urls: [URL], size: Int64) -> [[ScanItem]] {
        var groups: [String: [ScanItem]] = [:]
        var order: [String] = []
        for url in urls {
            let key = storageKey(url)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(
                ScanItem(url: url, sizeBytes: size, isDirectory: false))
        }
        return order.compactMap { groups[$0] }
    }

    /// Identity of a file's on-disk storage. Hardlinks share an inode;
    /// APFS clones share extents, which we detect by the physical offset of
    /// block zero (identical content + identical first-extent location ⇒
    /// shared storage). Falls back to the inode when the offset is
    /// unavailable, and to the path (always unique) if even stat fails.
    static func storageKey(_ url: URL) -> String {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return "path:\(url.path)" }
        if let physical = physicalStart(of: url.path) {
            return "\(st.st_dev):p\(physical)"
        }
        return "\(st.st_dev):i\(st.st_ino)"
    }

    /// Physical device offset of the file's first block via F_LOG2PHYS.
    private static func physicalStart(of path: String) -> UInt64? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var mapping = log2phys()
        guard fcntl(fd, F_LOG2PHYS, &mapping) == 0, mapping.l2p_devoffset >= 0 else {
            return nil
        }
        return UInt64(mapping.l2p_devoffset)
    }

    /// Streaming SHA-256; `limitBytes` nil hashes the whole file.
    private static func hash(_ url: URL, limitBytes: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limitBytes ?? Int.max
        while remaining > 0 {
            let chunkSize = min(remaining, 1 << 20)
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation

/// One completed cleanup — the honest, auditable counterpart to the "speed
/// boost" theater the app rejects. Only real (non-dry-run) executions are
/// recorded, so the running totals reflect bytes the user actually moved to
/// the Trash (reclaimable once the Trash is emptied).
public struct CleanupEntry: Identifiable, Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case deletion
        case dedup
        case uninstall
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let reclaimedBytes: Int64
    public let itemCount: Int

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        reclaimedBytes: Int64,
        itemCount: Int
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.reclaimedBytes = reclaimedBytes
        self.itemCount = itemCount
    }
}

/// Persistent history of completed cleanups, stored as JSON in the app's
/// Application Support folder. Powers the "MacTidy has freed X across N
/// cleanups" stat on the Overview.
public final class CleanupLog: @unchecked Sendable {
    public static let shared = CleanupLog()

    public static let maxEntries = 1000

    private let queue = DispatchQueue(label: "com.jayansh.mactidy.cleanuplog")
    private let fileURL: URL

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.fileURL = storageURL
        } else {
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/MacTidy")
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appending(path: "cleanup-log.json")
        }
    }

    public func load() -> [CleanupEntry] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let entries = try? JSONDecoder().decode([CleanupEntry].self, from: data)
            else { return [] }
            return entries.sorted { $0.date > $1.date }
        }
    }

    public func append(_ entry: CleanupEntry) {
        queue.sync {
            var existing = (try? JSONDecoder().decode(
                [CleanupEntry].self, from: Data(contentsOf: fileURL))) ?? []
            existing.append(entry)
            if existing.count > Self.maxEntries {
                existing = Array(existing.suffix(Self.maxEntries))
            }
            try? JSONEncoder().encode(existing).write(to: fileURL, options: .atomic)
        }
    }

    /// Total bytes reclaimed across all recorded cleanups.
    public var totalReclaimed: Int64 {
        load().reduce(0) { $0 + $1.reclaimedBytes }
    }

    /// Number of cleanups recorded.
    public var count: Int { load().count }

    public func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Removes entries older than the given number of days. No-op when `days`
    /// is zero or negative. The reclaimed-over-time stat only reflects what's
    /// still logged, so pruning narrows the window the stat covers.
    public func pruneOlderThan(days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  var entries = try? JSONDecoder().decode([CleanupEntry].self, from: data)
            else { return }
            let before = entries.count
            entries.removeAll { $0.date < cutoff }
            guard entries.count != before else { return }
            try? JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        }
    }
}
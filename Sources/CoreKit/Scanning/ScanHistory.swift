import Foundation

/// One snapshot of a completed scan, for the reclaimable-over-time trend on
/// the Overview. Only the aggregate is kept (not the full item list) so the
/// history stays small across many scans.
public struct ScanSnapshot: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public let date: Date
    public let reclaimableBytes: Int64
    public let itemCount: Int
    /// Bytes per category (keyed by `Category.rawValue`). Nil in snapshots
    /// written before growth tracking existed.
    public let categories: [String: Int64]?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        reclaimableBytes: Int64,
        itemCount: Int,
        categories: [String: Int64]? = nil
    ) {
        self.id = id
        self.date = date
        self.reclaimableBytes = reclaimableBytes
        self.itemCount = itemCount
        self.categories = categories
    }

    public init(results: [CategoryResult], date: Date = Date()) {
        self.init(date: date,
                  reclaimableBytes: results.reduce(0) { $0 + $1.totalBytes },
                  itemCount: results.reduce(0) { $0 + $1.items.count },
                  categories: Dictionary(results.map { ($0.category.rawValue, $0.totalBytes) },
                                         uniquingKeysWith: +))
    }
}

/// A category that grew between two scans.
public struct CategoryGrowth: Identifiable, Sendable, Equatable {
    public let category: Category
    public let delta: Int64
    public let current: Int64
    public let since: Date
    public var id: Category { category }
}

extension ScanHistory {
    /// Categories that grew by at least `minimumDelta` since the newest scan
    /// that is at least `minimumGap` older than the latest one. Biggest first.
    public static func growers(in history: [ScanSnapshot],
                               minimumDelta: Int64 = 100_000_000,
                               minimumGap: TimeInterval = 20 * 3600,
                               limit: Int = 4) -> [CategoryGrowth] {
        let tracked = history.filter { $0.categories != nil }.sorted { $0.date > $1.date }
        guard let latest = tracked.first, let now = latest.categories,
              let base = tracked.first(where: { latest.date.timeIntervalSince($0.date) >= minimumGap }),
              let before = base.categories else { return [] }
        return now.compactMap { key, bytes -> CategoryGrowth? in
            guard let category = Category(rawValue: key) else { return nil }
            let delta = bytes - (before[key] ?? 0)
            return delta >= minimumDelta ? CategoryGrowth(category: category, delta: delta, current: bytes, since: base.date) : nil
        }
        .sorted { $0.delta > $1.delta }
        .prefix(limit).map { $0 }
    }
}

/// Rolling history of recent scan snapshots, stored as JSON in the app's
/// Application Support folder. Capped at `maxSnapshots` so it can't grow
/// unbounded; newest first.
public final class ScanHistory: @unchecked Sendable {
    public static let shared = ScanHistory()

    public static let maxSnapshots = 50

    private let queue = DispatchQueue(label: "com.jayansh.mactidy.scanhistory")
    private let fileURL: URL

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.fileURL = storageURL
        } else {
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/MacTidy")
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appending(path: "scan-history.json")
        }
    }

    /// Loads the history, newest first.
    public func load() -> [ScanSnapshot] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let entries = try? JSONDecoder().decode([ScanSnapshot].self, from: data)
            else { return [] }
            return entries.sorted { $0.date > $1.date }
        }
    }

    public func append(_ snapshot: ScanSnapshot) {
        queue.sync {
            var existing = (try? JSONDecoder().decode(
                [ScanSnapshot].self, from: Data(contentsOf: fileURL))) ?? []
            existing.append(snapshot)
            if existing.count > Self.maxSnapshots {
                existing = Array(existing.suffix(Self.maxSnapshots))
            }
            try? JSONEncoder().encode(existing).write(to: fileURL, options: .atomic)
        }
    }

    public func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }
}
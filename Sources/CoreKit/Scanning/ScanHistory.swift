import Foundation

/// One snapshot of a completed scan, for the reclaimable-over-time trend on
/// the Overview. Only the aggregate is kept (not the full item list) so the
/// history stays small across many scans.
public struct ScanSnapshot: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public let date: Date
    public let reclaimableBytes: Int64
    public let itemCount: Int

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        reclaimableBytes: Int64,
        itemCount: Int
    ) {
        self.id = id
        self.date = date
        self.reclaimableBytes = reclaimableBytes
        self.itemCount = itemCount
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
import Foundation

/// One persistently recorded item MacTidy moved to the Trash, so it can be
/// surfaced in the "Recently Trashed" list and restored on demand. The
/// in-memory `TrashedRecord` is ephemeral (per-execution); this is its
/// on-disk counterpart that survives relaunches.
public struct TrashRecord: Identifiable, Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case deletion
        case dedup
        case uninstall
    }

    public let id: UUID
    public let originalPath: String
    /// Where the item landed in the Trash; nil only when a trashed item didn't
    /// report a location (records without a location are not persisted).
    public let trashPath: String?
    public let date: Date
    public let bytes: Int64
    public let kind: Kind

    public var original: URL { URL(fileURLWithPath: originalPath) }
    public var trashLocation: URL? { trashPath.map(URL.init(fileURLWithPath:)) }

    public init(
        id: UUID = UUID(),
        original: URL,
        trashLocation: URL?,
        date: Date,
        bytes: Int64,
        kind: Kind
    ) {
        self.id = id
        self.originalPath = original.path
        self.trashPath = trashLocation?.path
        self.date = date
        self.bytes = bytes
        self.kind = kind
    }
}

/// Persistent log of everything MacTidy has trashed, stored as JSON in the
/// app's Application Support folder. The Trash is the undo button; this log
/// is what makes that undo visible and one-click. Only records with a Trash
/// location are persisted — that's what makes them restorable.
public final class TrashLog: @unchecked Sendable {
    public static let shared = TrashLog()

    /// Cap so the log can't grow unbounded across years of use. Oldest entries
    /// are dropped first.
    public static let maxEntries = 500

    private let queue = DispatchQueue(label: "com.jayansh.mactidy.trashlog")
    private let fileURL: URL

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.fileURL = storageURL
        } else {
            let support = Self.supportDirectory()
            self.fileURL = support.appending(path: "trash-log.json")
        }
    }

    private static func supportDirectory() -> URL {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacTidy")
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    /// Loads the current log, newest first.
    public func load() -> [TrashRecord] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let records = try? JSONDecoder().decode([TrashRecord].self, from: data)
            else { return [] }
            return records.sorted { $0.date > $1.date }
        }
    }

    /// Appends fully-formed records. Records without a trash location are
    /// filtered out — there's nothing to undo without a Trash path.
    public func append(_ records: [TrashRecord]) {
        let persistable = records.filter { $0.trashLocation != nil }
        guard !persistable.isEmpty else { return }
        queue.sync {
            var existing = (try? JSONDecoder().decode(
                [TrashRecord].self, from: Data(contentsOf: fileURL))) ?? []
            existing.append(contentsOf: persistable)
            if existing.count > Self.maxEntries {
                existing = Array(existing.suffix(Self.maxEntries))
            }
            try? JSONEncoder().encode(existing).write(to: fileURL, options: .atomic)
        }
    }

    /// Removes a record after it has been restored (or the user dismissed it).
    public func remove(_ id: UUID) {
        queue.sync {
            var existing = (try? JSONDecoder().decode(
                [TrashRecord].self, from: Data(contentsOf: fileURL))) ?? []
            existing.removeAll { $0.id == id }
            try? JSONEncoder().encode(existing).write(to: fileURL, options: .atomic)
        }
    }

    public func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Reconciles the log against the actual Trash: drops records whose
    /// `trashLocation` no longer exists on disk (the user emptied the Trash
    /// in Finder, or restored+deleted the item elsewhere). Records with no
    /// recorded location are dropped too — there's nothing to undo. Read-only
    /// except for the log file itself; never touches the Trash. Returns the
    /// number of records pruned.
    @discardableResult
    public func pruneMissing() -> Int {
        let fm = FileManager.default
        return queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  var entries = try? JSONDecoder().decode([TrashRecord].self, from: data)
            else { return 0 }
            let before = entries.count
            entries.removeAll { record in
                guard let trash = record.trashLocation else { return true }
                return !fm.fileExists(atPath: trash.path)
            }
            let pruned = before - entries.count
            guard pruned > 0 else { return 0 }
            try? JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
            return pruned
        }
    }

    /// Removes records older than the given number of days. No-op when `days`
    /// is zero or negative. The items themselves stay in the Trash — only the
    /// undo log entries are dropped.
    public func pruneOlderThan(days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  var entries = try? JSONDecoder().decode([TrashRecord].self, from: data)
            else { return }
            let before = entries.count
            entries.removeAll { $0.date < cutoff }
            guard entries.count != before else { return }
            try? JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        }
    }
}

/// The restore side of the Trash undo: moves a trashed item back to its
/// original location. Like `Trasher`, this is a real filesystem mutation —
/// but a restorative one, moving *out* of the Trash rather than into it.
/// On a name collision at the original path, the restored item gets an
/// " (restored)" suffix so nothing is ever clobbered.
public enum Restorer {
    public enum RestoreError: Error, LocalizedError {
        case noTrashLocation
        case trashItemMissing(String)
        case restoreFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noTrashLocation:
                "This record has no Trash location to restore from."
            case .trashItemMissing(let path):
                "The item is no longer in the Trash (maybe emptied): \(path)"
            case .restoreFailed(let reason):
                "Could not move the item back: \(reason)"
            }
        }
    }

    @discardableResult
    public static func restore(_ record: TrashRecord) throws -> URL {
        let fm = FileManager.default
        guard let trashLocation = record.trashLocation else { throw RestoreError.noTrashLocation }
        guard fm.fileExists(atPath: trashLocation.path) else {
            throw RestoreError.trashItemMissing(trashLocation.path)
        }

        let original = record.original
        let parent = original.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        // If the original path is occupied again, restore beside it with a
        // suffix instead of overwriting whatever is there now.
        var destination = original
        if fm.fileExists(atPath: destination.path) {
            let stem = original.deletingPathExtension().lastPathComponent
            let ext = original.pathExtension
            let suffix = " (restored \(UUID().uuidString.prefix(6)))"
            let name = ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)"
            destination = parent.appending(path: name)
        }

        do {
            try fm.moveItem(at: trashLocation, to: destination)
            return destination
        } catch {
            throw RestoreError.restoreFailed(error.localizedDescription)
        }
    }
}
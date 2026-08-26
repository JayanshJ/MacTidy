import Darwin
import Foundation

/// Reclaims duplicate space with zero data loss: every extra copy is
/// replaced by an APFS clone of the kept copy, so both paths keep working
/// but the blocks are stored once. The replaced file's original bytes go to
/// the Trash (never `rm`), and the swap itself is atomic (RENAME_SWAP) —
/// at no point is the target path missing or holding partial data.
///
/// Mutation inventory, in order, per file: clonefile(2) to a temp name,
/// atomic swap with the target, move-to-Trash of the swapped-out original.
/// Any failure unwinds and leaves the target untouched.
public enum CloneDeduplicator {
    public struct Outcome: Sendable {
        /// One record per replaced copy; `trashLocation` is where its
        /// pre-dedup bytes went.
        public let deduplicated: [TrashedRecord]
        public let skipped: [SkippedRecord]
        public let reclaimedBytes: Int64
    }

    public enum DedupError: Error, LocalizedError {
        case notRegularFile
        case differentVolume
        case changedSinceScan
        case cloneFailed(Int32)
        case swapFailed(Int32)
        case trashFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notRegularFile: "Not a regular file anymore"
            case .differentVolume: "On a different volume than the kept copy — clones need the same volume"
            case .changedSinceScan: "File changed since the scan — rescan and retry"
            case .cloneFailed(let err):
                err == ENOTSUP
                    ? "Volume doesn't support cloning (not APFS)"
                    : "clonefile failed: \(String(cString: strerror(err)))"
            case .swapFailed(let err): "Atomic swap failed: \(String(cString: strerror(err)))"
            case .trashFailed(let reason): "Could not move original bytes to Trash: \(reason)"
            }
        }
    }

    /// Deduplicates one set: the first file of the first physical group is
    /// kept as-is; every file in the *other* physical groups is replaced by
    /// a clone of it. Files in the kept group are already sharing storage
    /// and are left alone. Each target is checked against the SafePathPolicy
    /// individually — a rejected target is skipped (with the reason) and the
    /// rest proceed, fail-closed per item.
    public static func deduplicate(
        _ set: DuplicateSet,
        policy: SafePathPolicy
    ) -> Outcome {
        guard let primary = set.physicalGroups.first?.first else {
            return Outcome(deduplicated: [], skipped: [], reclaimedBytes: 0)
        }
        let targets = set.physicalGroups.dropFirst().flatMap { $0 }

        var deduplicated: [TrashedRecord] = []
        var skipped: [SkippedRecord] = []
        var reclaimed: Int64 = 0

        for target in targets {
            switch policy.classify(target.url) {
            case .failure(let violation):
                skipped.append(SkippedRecord(url: target.url, reason: violation.description))
                continue
            case .success:
                break
            }
            do {
                let record = try replaceWithClone(of: primary.url, at: target.url,
                                                  expectedSize: set.fileSizeBytes)
                deduplicated.append(record)
                reclaimed += set.fileSizeBytes
                NSLog("MacTidy: deduplicated %@ (clone of %@)",
                      target.url.path, primary.url.path)
            } catch {
                skipped.append(SkippedRecord(url: target.url,
                                             reason: error.localizedDescription))
            }
        }
        return Outcome(deduplicated: deduplicated,
                       skipped: skipped, reclaimedBytes: reclaimed)
    }

    private static func replaceWithClone(
        of primary: URL, at target: URL, expectedSize: Int64
    ) throws -> TrashedRecord {
        let fm = FileManager.default

        var primaryStat = stat()
        var targetStat = stat()
        guard stat(primary.path, &primaryStat) == 0,
              lstat(target.path, &targetStat) == 0,
              targetStat.st_mode & S_IFMT == S_IFREG else {
            throw DedupError.notRegularFile
        }
        guard primaryStat.st_dev == targetStat.st_dev else {
            throw DedupError.differentVolume
        }
        // Content equality was established at scan time; a size change means
        // the file was modified since — refuse rather than clobber new data.
        guard Int64(targetStat.st_size) == expectedSize,
              Int64(primaryStat.st_size) == expectedSize else {
            throw DedupError.changedSinceScan
        }

        // Clone next to the target so the swap stays on one volume. The name
        // is user-visible only for the instant of the swap, and becomes the
        // Trash name of the original bytes afterwards.
        let ext = target.pathExtension
        let stem = target.deletingPathExtension().lastPathComponent
        let suffix = " (MacTidy pre-dedup \(UUID().uuidString.prefix(8)))"
        let tmpName = ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)"
        let tmp = target.deletingLastPathComponent().appending(path: tmpName)

        guard clonefile(primary.path, tmp.path, 0) == 0 else {
            throw DedupError.cloneFailed(errno)
        }
        // From here on, failure must remove the temp clone (our own
        // artifact, not user data) and leave the target untouched.
        do {
            // Keep the target's own permissions and mtime on its replacement.
            let attributes = try fm.attributesOfItem(atPath: target.path)
            var preserved: [FileAttributeKey: Any] = [:]
            for key in [FileAttributeKey.posixPermissions, .modificationDate] {
                if let value = attributes[key] { preserved[key] = value }
            }
            try? fm.setAttributes(preserved, ofItemAtPath: tmp.path)

            guard renamex_np(tmp.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                throw DedupError.swapFailed(errno)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }

        // Target path now holds the clone; tmp holds the original bytes.
        do {
            let trashLocation = try Trasher.trash(tmp)
            return TrashedRecord(original: target, trashLocation: trashLocation)
        } catch {
            // Undo completely: swap back, drop our clone.
            _ = renamex_np(tmp.path, target.path, UInt32(RENAME_SWAP))
            try? fm.removeItem(at: tmp)
            throw DedupError.trashFailed(error.localizedDescription)
        }
    }
}

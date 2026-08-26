import Foundation

/// Read-only sizing of the user's macOS Trash (`~/.Trash`). Used by the
/// Overview nudge that points out the Trash itself holds reclaimable space —
/// MacTidy moves everything *to* the Trash but never empties it (an explicit
/// invariant), so reminding the user to empty it in Finder closes the reclaim
/// loop honestly.
///
/// This is display-only: it never deletes, never empties, never modifies the
/// Trash in any way.
public enum TrashUsage {
    /// The user's Trash directory.
    public static var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
    }

    /// Total bytes currently in the Trash (real on-disk allocated size, no
    /// symlink following). Returns 0 when the Trash is empty or missing.
    public static func totalBytes() -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashURL.path) else { return 0 }
        return DiskScanner.allocatedSize(of: trashURL)
    }
}
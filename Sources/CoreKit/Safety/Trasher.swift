import Foundation

/// The only place in the codebase that mutates the filesystem destructively.
/// "Destructive" means move-to-Trash, never `removeItem` — the Trash is the
/// undo button. If an item can't be trashed (permissions, system-owned),
/// callers must skip and report it, never fall back to a hard delete.
public enum Trasher {
    /// Moves a URL to the Trash. Returns the new in-Trash location.
    @discardableResult
    public static func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let resulting else {
            // trashItem succeeded but didn't report a location; extremely
            // unlikely, but don't crash on a force-unwrap in the safety layer.
            return url
        }
        return resulting as URL
    }
}

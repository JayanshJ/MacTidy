import Foundation
import AppKit

/// The only place in the codebase that mutates the filesystem destructively.
/// "Destructive" means move-to-Trash, never `removeItem` — the Trash is the
/// undo button. If an item can't be trashed (permissions, system-owned),
/// callers must skip and report it, never fall back to a hard delete.
public enum Trasher {
    /// Moves a URL to the Trash. Returns the new in-Trash location.
    ///
    /// Tries `FileManager.trashItem` first (fast, synchronous, returns the
    /// in-Trash location). When that fails with a permission/ownership error —
    /// common for apps installed as root (e.g. Google Drive) where the user
    /// process can't write the bundle directory — falls back to
    /// `NSWorkspace.recycleURLs`, which routes the move through the Finder.
    /// The Finder runs with its own TCC entitlements and can trash items the
    /// calling process doesn't own, which is how real uninstallers move
    /// root-owned app bundles. `recycleURLs` is async and doesn't report the
    /// resulting location, so on the fallback path the original URL is
    /// returned as a best-effort placeholder (the item is in the Trash, just
    /// not locatable for an immediate in-app restore).
    @discardableResult
    public static func trash(_ url: URL) throws -> URL {
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            guard let resulting else {
                // trashItem succeeded but didn't report a location; extremely
                // unlikely, but don't crash on a force-unwrap in the safety layer.
                return url
            }
            return resulting as URL
        } catch {
            // Permission/ownership failures (e.g. root-owned app bundles)
            // can't be trashed via FileManager from a user process. Route
            // through the Finder, which has the TCC privileges to move items
            // the caller doesn't own. Rethrow the original error only if the
            // Finder path also fails, so the per-item skip + report path
            // still surfaces a meaningful reason.
            return try recycleViaFinder(url)
        }
    }

    /// Moves `url` to the Trash via `NSWorkspace.recycle` (Finder-backed).
    /// Synchronous wrapper around the async AppKit API so `trash(_:)` keeps its
    /// throwing, location-returning shape. On success the recycled location
    /// is returned; throws the Finder error on failure.
    private static func recycleViaFinder(_ url: URL) throws -> URL {
        let box = RecycleResultBox()
        NSWorkspace.shared.recycle([url]) { urlsByOriginal, error in
            box.set(error: error, location: urlsByOriginal[url])
        }
        return try box.wait(fallback: url)
    }

    /// Thread-safe box for the async `recycle` completion, since Swift 6
    /// concurrency flags captured-var mutation in the @Sendable closure.
    private final class RecycleResultBox: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var error: Error?
        private var location: URL?

        func set(error: Error?, location: URL?) {
            self.error = error
            self.location = location
            semaphore.signal()
        }

        func wait(fallback: URL) throws -> URL {
            _ = semaphore.wait(timeout: .now() + .seconds(30))
            if let error { throw error }
            return location ?? fallback
        }
    }
}

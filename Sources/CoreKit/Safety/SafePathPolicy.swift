import Foundation

/// Last line of defense against catastrophic deletes. The deletion layer
/// validates every candidate against this policy regardless of what a
/// scanner proposed, so a scanner bug cannot escalate into `/System` or
/// the user's documents being trashed.
///
/// The policy is deny-by-default: on top of the hard denylist, a candidate
/// must live *inside* one of the allowed roots (home, /Applications,
/// /usr/local, /opt/homebrew, or a folder the user explicitly picked).
/// All paths are symlink-resolved before checking, so a symlink pointing
/// into a protected area is rejected even if it sits in an allowed root.
public struct SafePathPolicy: Sendable {
    public enum Violation: Error, Equatable, CustomStringConvertible {
        case deniedSystemPath(String)
        case criticalDirectory(String)
        case protectedUserFolder(String)
        case outsideAllowedRoots(String)

        public var description: String {
            switch self {
            case .deniedSystemPath(let p): "Refusing to touch system path: \(p)"
            case .criticalDirectory(let p): "Refusing to delete critical directory itself: \(p)"
            case .protectedUserFolder(let p): "Refusing to touch protected personal folder: \(p)"
            case .outsideAllowedRoots(let p): "Path is outside every allowed root: \(p)"
            }
        }
    }

    public let home: URL
    /// Folders the user explicitly picked (e.g. duplicate-finder roots).
    /// These unlock deletion inside otherwise-protected personal folders,
    /// but can never override the system denylist.
    public var extraAllowedRoots: [URL]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraAllowedRoots: [URL] = []
    ) {
        self.home = home
        self.extraAllowedRoots = extraAllowedRoots
    }

    /// Validates every URL and throws on the first violation. Use this when
    /// you want strict all-or-nothing semantics (e.g. a single atomic
    /// operation that should refuse entirely if any path is bad).
    public func validate(_ urls: [URL]) throws {
        for url in urls { try validate(url) }
    }

    /// Throws on violation. Convenience over `classify`.
    public func validate(_ url: URL) throws {
        switch classify(url) {
        case .success: return
        case .failure(let violation): throw violation
        }
    }

    /// Judges a single path without throwing. The deletion layer uses this to
    /// partition a plan into valid/invalid up front so one bad path skips only
    /// itself (reported to the user) instead of aborting the whole plan —
    /// fail-closed *per item*, never touching anything the policy rejects.
    public func classify(_ url: URL) -> Result<URL, Violation> {
        let path = Self.canonical(url)
        let home = Self.canonical(self.home)
        let extras = extraAllowedRoots.map(Self.canonical)

        // 1. Hard system denylist. Nothing overrides these.
        if path == "/" { return .failure(.criticalDirectory(path)) }
        for prefix in ["/System", "/bin", "/sbin", "/Library/Apple", "/private/etc", "/etc"]
        where Self.path(path, isSameOrUnder: prefix) {
            return .failure(.deniedSystemPath(path))
        }
        if Self.path(path, isSameOrUnder: "/usr"),
            !Self.path(path, isSameOrUnder: "/usr/local") {
            return .failure(.deniedSystemPath(path))
        }

        // 2. Critical directories may contain deletable items but must never
        //    be deleted wholesale themselves.
        let critical = [
            home,
            home + "/Library",
            home + "/Library/Application Support",
            home + "/Library/Preferences",
            home + "/Library/Caches",
            home + "/Downloads",
            "/Applications", "/Library", "/Users", "/usr/local", "/opt/homebrew",
        ]
        if critical.contains(path) { return .failure(.criticalDirectory(path)) }

        // 3. User-picked roots unlock personal folders (duplicate finder),
        //    checked after the denylist so they can't unlock system paths.
        if extras.contains(where: { Self.path(path, isSameOrUnder: $0) }) {
            return .success(url)
        }

        // 4. Personal folders are off-limits unless explicitly picked above.
        for folder in ["Documents", "Desktop", "Pictures", "Movies", "Music"]
        where Self.path(path, isSameOrUnder: home + "/" + folder) {
            return .failure(.protectedUserFolder(path))
        }

        // 5. Deny-by-default: must be inside some allowed root.
        let allowedRoots = [home, "/Applications", "/usr/local", "/opt/homebrew"]
        guard allowedRoots.contains(where: { Self.path(path, isSameOrUnder: $0) }) else {
            return .failure(.outsideAllowedRoots(path))
        }
        return .success(url)
    }

    /// Symlink-resolved, standardized absolute path. Resolving first means a
    /// symlink at an allowed location pointing somewhere protected is judged
    /// by its destination.
    static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func path(_ path: String, isSameOrUnder prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }
}

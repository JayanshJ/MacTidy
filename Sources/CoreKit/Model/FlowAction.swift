import Foundation

/// One actionable step in the guided cleanup flow. Each action is a single
/// thing the user can review and either trash/apply or skip. The flow walks a
/// ranked queue of these, one at a time.
///
/// This is the unified currency of the redesigned app: cleanup categories,
/// uninstaller suggestions, startup-item suggestions, and duplicate sets all
/// surface as `FlowAction`s so the wizard can present them with one shape.
public enum FlowAction: Identifiable, Sendable {
    /// Trash a set of scanned items (a cleanup category slice, big files, etc.).
    case trash(items: [ScanItem], title: String, why: String, icon: String)
    /// Uninstall an app plus its orphaned leftovers.
    case uninstall(app: InstalledApp, leftovers: [ScanItem])
    /// Disable one or more launch items.
    case disableLaunch(items: [LaunchItem])
    /// Review duplicate sets (the user must pick folders first, so this is a
    /// gateway action that opens the duplicate picker).
    case reviewDuplicates

    public var id: String {
        switch self {
        case .trash(let items, _, _, _):
            "trash:" + items.map(\.url.path).joined(separator: "|")
        case .uninstall(let app, _):
            "uninstall:" + app.id
        case .disableLaunch(let items):
            "launch:" + items.map(\.url.path).joined(separator: "|")
        case .reviewDuplicates:
            "reviewDuplicates"
        }
    }

    /// A short, human title for the action card.
    public var title: String {
        switch self {
        case .trash(_, let title, _, _): return title
        case .uninstall(let app, _): return "Uninstall \(app.name)"
        case .disableLaunch(let items):
            return items.count == 1 ? "Disable \(items[0].label)" : "Disable \(items.count) launch items"
        case .reviewDuplicates: return "Review duplicate files"
        }
    }

    /// One plain-language line explaining why this is safe / worth doing.
    public var why: String {
        switch self {
        case .trash(_, _, let why, _): return why
        case .uninstall(let app, let leftovers):
            let leftover = leftovers.reduce(0) { $0 + $1.sizeBytes }
            if leftover > 0 {
                return "Removes the \(app.sizeBytes.formattedBytes) app plus \(leftover.formattedBytes) of orphaned data in ~/Library."
            }
            return "Moves the app to the Trash. Leftover data, if any, can be restored from the Trash."
        case .disableLaunch(let items):
            let loaded = items.filter(\.isLoaded).count
            return "Login items run every time you log in. \(loaded) currently loaded — disabling parks the plist so it won't run next login. Reversible."
        case .reviewDuplicates:
            return "Duplicate files waste space. Pick folders to scan by content (SHA-256), then trash or deduplicate the extra copies."
        }
    }

    public var icon: String {
        switch self {
        case .trash(_, _, _, let icon): return icon
        case .uninstall: return "trash.slash"
        case .disableLaunch: return "power"
        case .reviewDuplicates: return "doc.on.doc"
        }
    }

    /// Total bytes this action would reclaim, for ranking and display.
    public var reclaimableBytes: Int64 {
        switch self {
        case .trash(let items, _, _, _): items.reduce(0) { $0 + $1.sizeBytes }
        case .uninstall(let app, let leftovers):
            app.sizeBytes + leftovers.reduce(0) { $0 + $1.sizeBytes }
        case .disableLaunch: 0
        case .reviewDuplicates: 0
        }
    }
}

/// The states the guided flow moves through.
public enum FlowPhase: Sendable, Equatable {
    case welcome
    case scanning
    case dashboard
    case allClean
}

/// Tracks the dry-pass state. The wizard does a dry run first (trashes
/// nothing), then offers a real pass.
public enum CleanPass: Sendable, Equatable {
    case dry
    case real
}
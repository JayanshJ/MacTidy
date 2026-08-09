import Foundation

public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Domain: String, CaseIterable, Sendable {
        case userAgent = "User launch agents"
        case systemAgent = "System launch agents"
        case systemDaemon = "System launch daemons"

        /// Only user agents are toggleable in v1. System items would need a
        /// privileged helper; they're shown read-only.
        public var isToggleable: Bool { self == .userAgent }
    }

    public let url: URL
    public let label: String
    public let program: String?
    public let runAtLoad: Bool?
    public let isLoaded: Bool
    public let domain: Domain
    public var id: String { url.path }
}

/// Audits launchd plists — the real levers behind "my Mac starts slow".
/// Disabling is reversible by design: bootout + move the plist into an
/// app-managed folder, never delete it.
public enum LaunchItemsAuditor {
    public static var disabledFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacTidy/Disabled LaunchAgents")
    }

    public static func audit() -> [LaunchItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sources: [(URL, LaunchItem.Domain)] = [
            (home.appending(path: "Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
        let loadedLabels = currentlyLoadedLabels()

        var items: [LaunchItem] = []
        for (dir, domain) in sources {
            let plists = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in plists where url.pathExtension == "plist" {
                items.append(read(url, domain: domain, loadedLabels: loadedLabels))
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Plists previously disabled by MacTidy, available for restore.
    public static func disabledItems() -> [LaunchItem] {
        let plists = (try? FileManager.default.contentsOfDirectory(
            at: disabledFolder, includingPropertiesForKeys: nil)) ?? []
        return plists
            .filter { $0.pathExtension == "plist" }
            .map { read($0, domain: .userAgent, loadedLabels: []) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private static func read(_ url: URL, domain: LaunchItem.Domain,
                             loadedLabels: Set<String>) -> LaunchItem {
        var label = url.deletingPathExtension().lastPathComponent
        var program: String?
        var runAtLoad: Bool?
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] {
            label = plist["Label"] as? String ?? label
            program = plist["Program"] as? String
                ?? (plist["ProgramArguments"] as? [String])?.joined(separator: " ")
            runAtLoad = plist["RunAtLoad"] as? Bool
        }
        return LaunchItem(url: url, label: label, program: program,
                          runAtLoad: runAtLoad,
                          isLoaded: loadedLabels.contains(label), domain: domain)
    }

    /// Labels from `launchctl list` (third column). Empty set if launchctl
    /// is unavailable for some reason — the audit still works, just without
    /// the "loaded" badge.
    public static func currentlyLoadedLabels() -> Set<String> {
        guard let output = Shell.run("/bin/launchctl", ["list"]), output.succeeded else { return [] }
        var labels = Set<String>()
        for line in output.stdout.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            if columns.count >= 3 { labels.insert(String(columns[2])) }
        }
        return labels
    }

    public enum AuditError: Error, LocalizedError {
        case notToggleable
        case moveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notToggleable:
                "Only user launch agents can be disabled. System items need admin rights (out of scope)."
            case .moveFailed(let reason):
                "Could not move the plist: \(reason)"
            }
        }
    }

    /// Reversibly disables a user agent: bootout from launchd, then park the
    /// plist in the app-managed Disabled folder so Restore can undo it.
    public static func disable(_ item: LaunchItem) throws {
        guard item.domain.isToggleable else { throw AuditError.notToggleable }
        let uid = getuid()
        // Bootout can fail if the job simply isn't loaded; that's fine —
        // moving the plist is what prevents it from loading next login.
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"])

        let fm = FileManager.default
        try fm.createDirectory(at: disabledFolder, withIntermediateDirectories: true)
        let destination = disabledFolder.appending(path: item.url.lastPathComponent)
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: item.url, to: destination)
        } catch {
            throw AuditError.moveFailed(error.localizedDescription)
        }
    }

    /// Moves a parked plist back into ~/Library/LaunchAgents and bootstraps it.
    public static func restore(_ item: LaunchItem) throws {
        let fm = FileManager.default
        let agents = fm.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let destination = agents.appending(path: item.url.lastPathComponent)
        do {
            try fm.moveItem(at: item.url, to: destination)
        } catch {
            throw AuditError.moveFailed(error.localizedDescription)
        }
        _ = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", destination.path])
    }
}

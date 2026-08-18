import Foundation

public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Domain: String, CaseIterable, Sendable {
        case userAgent = "User launch agents"
        case systemAgent = "System launch agents"
        case systemDaemon = "System launch daemons"

        /// User agents toggle without privilege. System agents/daemons need
        /// admin rights, which MacTidy obtains via an `osascript` admin
        /// prompt per action (no embedded privileged helper).
        public var isToggleable: Bool { true }
        public var requiresAdmin: Bool { self != .userAgent }

        /// Where plists of this domain live on disk.
        public var sourceDirectory: URL {
            switch self {
            case .userAgent:
                FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Library/LaunchAgents")
            case .systemAgent:
                URL(fileURLWithPath: "/Library/LaunchAgents")
            case .systemDaemon:
                URL(fileURLWithPath: "/Library/LaunchDaemons")
            }
        }

        /// The launchd domain target used by bootout/bootstrap, e.g.
        /// `gui/501/<label>` for user agents or `system/<label>` for daemons.
        public func domainTarget(label: String) -> String {
            switch self {
            case .userAgent: "gui/\(getuid())/\(label)"
            case .systemAgent, .systemDaemon: "system/\(label)"
            }
        }
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
/// app-managed folder, never delete it. System agents/daemons need admin
/// rights, which MacTidy obtains via an `osascript` admin prompt.
public enum LaunchItemsAuditor {
    public static var disabledFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacTidy/Disabled LaunchAgents")
    }

    /// Where a disabled plist is parked, per domain. System-domain plists are
    /// parked in subfolders so Restore knows where to put them back.
    static func disabledFolder(for domain: LaunchItem.Domain) -> URL {
        switch domain {
        case .userAgent: disabledFolder
        case .systemAgent: disabledFolder.appending(path: "SystemAgents")
        case .systemDaemon: disabledFolder.appending(path: "SystemDaemons")
        }
    }

    public static func audit() -> [LaunchItem] {
        let sources: [(URL, LaunchItem.Domain)] = [
            (LaunchItem.Domain.userAgent.sourceDirectory, .userAgent),
            (LaunchItem.Domain.systemAgent.sourceDirectory, .systemAgent),
            (LaunchItem.Domain.systemDaemon.sourceDirectory, .systemDaemon),
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

    /// Plists previously disabled by MacTidy, available for restore. Each
    /// parked item is tagged with its original domain via the subfolder it
    /// lives in.
    public static func disabledItems() -> [LaunchItem] {
        var items: [LaunchItem] = []
        for domain in LaunchItem.Domain.allCases {
            let folder = disabledFolder(for: domain)
            let plists = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in plists where url.pathExtension == "plist" {
                items.append(read(url, domain: domain, loadedLabels: []))
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
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
        case adminPromptCancelled
        case adminCommandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notToggleable:
                "This launch item can't be toggled."
            case .moveFailed(let reason):
                "Could not move the plist: \(reason)"
            case .adminPromptCancelled:
                "Administrator permission was required and you cancelled the prompt."
            case .adminCommandFailed(let reason):
                "The privileged launchctl command failed: \(reason)"
            }
        }
    }

    /// Reversibly disables a launch item: bootout from launchd, then park the
    /// plist in the app-managed Disabled folder so Restore can undo it. System
    /// agents/daemons run their bootout + move via an `osascript` admin prompt.
    public static func disable(_ item: LaunchItem) throws {
        let fm = FileManager.default
        let destination = disabledFolder(for: item.domain)
            .appending(path: item.url.lastPathComponent)

        if item.domain.requiresAdmin {
            // One privileged shell that boots out, ensures the parked folder,
            // and moves the plist — so the user sees a single auth prompt.
            let bootout = "launchctl bootout \(item.domain.domainTarget(label: item.label)) 2>/dev/null || true"
            let mkdir = "mkdir -p \(quote(destination.deletingLastPathComponent().path))"
            let move = "mv -f \(quote(item.url.path)) \(quote(destination.path))"
            try runPrivileged(commands: [bootout, mkdir, move])
        } else {
            let uid = getuid()
            // Bootout can fail if the job simply isn't loaded; that's fine —
            // moving the plist is what prevents it from loading next login.
            _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"])
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: item.url, to: destination)
            } catch {
                throw AuditError.moveFailed(error.localizedDescription)
            }
        }
    }

    /// Moves a parked plist back to its original domain directory and
    /// bootstraps it. System-domain restores run via an `osascript` admin
    /// prompt.
    public static func restore(_ item: LaunchItem) throws {
        let fm = FileManager.default
        let destination = item.domain.sourceDirectory
            .appending(path: item.url.lastPathComponent)

        if item.domain.requiresAdmin {
            let mkdir = "mkdir -p \(quote(destination.deletingLastPathComponent().path))"
            let move = "mv -f \(quote(item.url.path)) \(quote(destination.path))"
            let bootstrap = "launchctl bootstrap \(item.domain.domainTarget(label: item.label)) \(quote(destination.path)) 2>/dev/null || true"
            try runPrivileged(commands: [mkdir, move, bootstrap])
        } else {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: item.url, to: destination)
            } catch {
                throw AuditError.moveFailed(error.localizedDescription)
            }
            _ = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", destination.path])
        }
    }

    /// Runs shell commands with administrator privileges via `osascript`,
    /// which surfaces macOS's standard auth dialog. Commands are joined into
    /// one `do shell script` so the user sees a single prompt.
    static func runPrivileged(commands: [String]) throws {
        let script = commands.joined(separator: " ; ")
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let out = Shell.run("/usr/bin/osascript", ["-e", appleScript])
        guard let out else { throw AuditError.adminCommandFailed("osascript unavailable") }
        // osascript exits 1 with "User canceled" when the auth dialog is
        // dismissed — distinguish that from a real command failure.
        if !out.succeeded {
            if out.stderr.contains("User canceled") || out.stderr.contains("-128") {
                throw AuditError.adminPromptCancelled
            }
            throw AuditError.adminCommandFailed(out.stderr.isEmpty ? out.stdout : out.stderr)
        }
    }

    /// Shell-quotes a path so spaces / special chars in plist names survive the
    /// round-trip through `do shell script`.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

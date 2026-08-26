import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let sizeBytes: Int64
    public var id: String { url.path }

    /// Apple's own apps are listed but not uninstallable — trashing them
    /// fails or breaks things, so don't offer it.
    public var isApple: Bool { bundleID?.hasPrefix("com.apple.") == true }
}

/// A non-file step an uninstall should perform that can't be expressed as a
/// path to trash — e.g. revoking TCC privacy permissions or unregistering
/// the app from LaunchServices. These run alongside the file deletions and
/// report their own success/failure, so a failed TCC reset never aborts the
/// uninstall or rolls back trashed files.
public struct UninstallAction: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case tccReset = "Privacy permissions"
        case lsregister = "LaunchServices registration"

        public var icon: String {
            switch self {
            case .tccReset: "lock.shield"
            case .lsregister: "doc.text.magnifyingglass"
            }
        }

        /// What the action does, shown in the confirmation preview.
        public var explanation: String {
            switch self {
            case .tccReset:
                "Reset this app's TCC privacy grants (Full Disk Access, Camera, Microphone, etc.) via tccutil."
            case .lsregister:
                "Unregister the app's file types / UTIs / Spotlight & QuickLook handlers from LaunchServices."
            }
        }
    }

    public let id = UUID()
    public let kind: Kind
    /// Human-readable target, e.g. the bundle id or app path.
    public let target: String

    public init(kind: Kind, target: String) {
        self.kind = kind
        self.target = target
    }
}

/// Result of running the non-file uninstall actions for one app.
public struct UninstallActionOutcome: Sendable {
    public struct StepResult: Identifiable, Sendable {
        public let id = UUID()
        public let action: UninstallAction
        public let succeeded: Bool
        public let message: String
    }
    public let results: [StepResult]
    public var succeededCount: Int { results.filter(\.succeeded).count }
    public var failedCount: Int { results.count - succeededCount }
}

/// Enumerates installed apps and finds the orphaned data an uninstall
/// should sweep up. Read-only; deletion goes through DeletionPlan.
public enum AppUninstaller {
    public static func installedApps() async -> [InstalledApp] {
        let fm = FileManager.default
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ]
        var bundles: [URL] = []
        for dir in dirs {
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            bundles.append(contentsOf: entries.filter { $0.pathExtension == "app" })
        }

        return await withTaskGroup(of: InstalledApp?.self) { group in
            for bundle in bundles {
                group.addTask { readApp(at: bundle) }
            }
            var apps: [InstalledApp] = []
            for await app in group where app != nil {
                apps.append(app!)
            }
            return apps.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private static func readApp(at bundle: URL) -> InstalledApp? {
        let plistURL = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundle.deletingPathExtension().lastPathComponent
        return InstalledApp(
            url: bundle,
            name: name,
            bundleID: plist["CFBundleIdentifier"] as? String,
            sizeBytes: DiskScanner.allocatedSize(of: bundle)
        )
    }

    /// Orphaned data left behind by an app, matched by bundle ID (exact) and
    /// app name (exact directory name only — substring matching on names is
    /// how cleaners eat unrelated data).
    public static func leftovers(for app: InstalledApp) async -> [ScanItem] {
        await leftovers(for: app, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Internal entry point that takes an explicit home directory so the
    /// orphan-detection logic is unit-testable against a throwaway Library
    /// tree without touching the real user home.
    static func leftovers(for app: InstalledApp, home: URL) async -> [ScanItem] {
        let fm = FileManager.default
        let library = home.appending(path: "Library")
        var candidates: [URL] = []

        if let id = app.bundleID, !id.isEmpty {
            candidates += [
                library.appending(path: "Application Support/\(id)"),
                library.appending(path: "Caches/\(id)"),
                library.appending(path: "Preferences/\(id).plist"),
                library.appending(path: "Saved Application State/\(id).savedState"),
                library.appending(path: "Containers/\(id)"),
                library.appending(path: "Logs/\(id)"),
                library.appending(path: "LaunchAgents/\(id).plist"),
                library.appending(path: "HTTPStorages/\(id)"),
                library.appending(path: "WebKit/\(id)"),
            ]
            // ByHost preferences: ~/Library/Preferences/ByHost/<id>.<uuid>.plist.
            // The host UUID suffix means we can't predict the exact name, so list
            // the directory and match entries whose name *starts with* the bundle
            // id followed by a "." — a prefix match, not a loose substring match,
            // so an unrelated bundle id that merely shares a prefix word can't be
            // swept up.
            let byHost = library.appending(path: "Preferences/ByHost")
            for entry in (try? fm.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent.hasPrefix("\(id).") {
                candidates.append(entry)
            }
            // CrashReporter / DiagnosticReports: <id>-*.crash and <id>-*.ips.
            let diag = library.appending(path: "Logs/DiagnosticReports")
            for entry in (try? fm.contentsOfDirectory(at: diag, includingPropertiesForKeys: nil)) ?? []
            where {
                let name = entry.lastPathComponent
                return name.hasPrefix("\(id)-") || name.hasPrefix("\(id).")
            }() {
                candidates.append(entry)
            }
            // Group containers are "<team-id>.<id>" (or occasionally "<id>").
            // Match a directory whose name ends with ".<id>" or equals <id> —
            // an anchored suffix/equal match rather than a loose contains, so a
            // bundle id can't match an unrelated group container that merely
            // embeds the id as a substring.
            let groups = library.appending(path: "Group Containers")
            for entry in (try? fm.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? []
            where {
                let name = entry.lastPathComponent
                return name == id || name.hasSuffix(".\(id)")
            }() {
                candidates.append(entry)
            }
        }
        if !app.name.isEmpty {
            candidates += [
                library.appending(path: "Application Support/\(app.name)"),
                library.appending(path: "Logs/\(app.name)"),
            ]
        }

        let existing = candidates
            .filter { fm.fileExists(atPath: $0.path) }
            .reduce(into: [URL]()) { unique, url in
                if !unique.contains(url) { unique.append(url) }
            }

        return await withTaskGroup(of: ScanItem.self) { group in
            for url in existing {
                group.addTask {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    return ScanItem(url: url,
                                    sizeBytes: DiskScanner.allocatedSize(of: url),
                                    isDirectory: isDir.boolValue)
                }
            }
            var items: [ScanItem] = []
            for await item in group { items.append(item) }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    /// The non-file steps an uninstall of this app should perform: TCC
    /// privacy-permission reset and LaunchServices unregistration. These are
    /// safe to run only for non-Apple apps with a known bundle id.
    public static func actions(for app: InstalledApp) -> [UninstallAction] {
        guard !app.isApple, let id = app.bundleID, !id.isEmpty else { return [] }
        return [
            UninstallAction(kind: .tccReset, target: id),
            UninstallAction(kind: .lsregister, target: app.url.path),
        ]
    }

    /// Runs the non-file uninstall actions (TCC reset, lsregister). Each runs
    /// independently and reports its own result, so one failure never aborts
    /// the others or rolls back trashed files.
    @discardableResult
    public static func performActions(
        _ actions: [UninstallAction]
    ) -> UninstallActionOutcome {
        var results: [UninstallActionOutcome.StepResult] = []
        for action in actions {
            switch action.kind {
            case .tccReset:
                // `tccutil reset All <bundleid>` revokes every TCC grant for
                // the app. Works for the current user's own apps without admin
                // rights. Degrades gracefully if tccutil is unavailable.
                let out = Shell.run("/usr/bin/tccutil", ["reset", "All", action.target])
                if let out {
                    results.append(.init(
                        action: action, succeeded: out.succeeded,
                        message: out.succeeded ? "Privacy permissions reset." : out.stderr
                    ))
                } else {
                    results.append(.init(action: action, succeeded: false,
                                         message: "tccutil not found."))
                }
            case .lsregister:
                // Unregister the bundle path so its file-type/UTI/Spotlight/
                // QuickLook handler registrations are dropped. lsregister is
                // found via Shell.find (it's in a non-standard location).
                let path = action.target
                if let lsregister = Shell.find("lsregister")
                    ?? FileManager.default.lsregisterPath() {
                    let out = Shell.run(lsregister, ["-u", path])
                    if let out {
                        results.append(.init(
                            action: action, succeeded: out.succeeded,
                            message: out.succeeded
                                ? "Unregistered from LaunchServices."
                                : (out.stderr.isEmpty ? out.stdout : out.stderr)
                        ))
                    } else {
                        results.append(.init(action: action, succeeded: false,
                                             message: "lsregister failed to launch."))
                    }
                } else {
                    results.append(.init(action: action, succeeded: false,
                                         message: "lsregister not found."))
                }
            }
        }
        return UninstallActionOutcome(results: results)
    }
}

private extension FileManager {
    /// Locates the LaunchServices `lsregister` binary inside CoreServices.
    /// It's not on PATH and not in any standard bin dir, so `Shell.find`
    /// can't reach it — resolve it from the framework bundle directly.
    func lsregisterPath() -> String? {
        // The FS framework moved to a versioned Frameworks path on modern macOS.
        let candidates = [
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister",
        ]
        for path in candidates where isExecutableFile(atPath: path) { return path }
        return nil
    }
}

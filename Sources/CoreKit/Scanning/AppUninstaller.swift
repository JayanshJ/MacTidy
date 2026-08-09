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
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appending(path: "Library")
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
            // Group containers are "<team-id>.<id>" or similar — match contains.
            let groups = library.appending(path: "Group Containers")
            for entry in (try? fm.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent.localizedCaseInsensitiveContains(id) {
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
}

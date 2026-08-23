import Foundation

/// One app's storage footprint, aggregated across every ~/Library location
/// MacTidy knows about. The "where exactly" answer: drill in to see each path
/// bucketed by kind (Caches, App Support, Containers, …).
public struct AppFootprint: Identifiable, Sendable, Hashable {
    public enum Bucket: String, CaseIterable, Sendable {
        case caches = "Caches"
        case appSupport = "Application Support"
        case containers = "Containers"
        case groupContainers = "Group Containers"
        case logs = "Logs"
        case savedState = "Saved Application State"
        case httpStorages = "HTTPStorages"
        case webKit = "WebKit"
        case preferences = "Preferences"

        public var displayName: String { rawValue }
    }

    /// One attributed path under the app, with its kind and size.
    public struct Path: Identifiable, Sendable, Hashable {
        public let url: URL
        public let bucket: Bucket
        public let sizeBytes: Int64
        public var id: String { url.path }
    }

    public let app: InstalledApp
    /// Matched paths (caches, containers, etc.). May be empty if the app
    /// stores nothing outside its bundle.
    public let paths: [Path]
    /// Total bytes across `paths` (does NOT include the app bundle — that's
    /// `app.sizeBytes`).
    public var libraryBytes: Int64 { paths.reduce(0) { $0 + $1.sizeBytes } }
    /// App bundle + library data.
    public var totalBytes: Int64 { app.sizeBytes + libraryBytes }

    public var id: String { app.id }

    public var bucketTotals: [(Bucket, Int64)] {
        Bucket.allCases.map { bucket in
            (bucket, paths.filter { $0.bucket == bucket }.reduce(0) { $0 + $1.sizeBytes })
        }.filter { $0.1 > 0 }
    }
}

/// Maps ~/Library subfolders back to the installed app that owns them, by
/// bundle ID (exact) or app name (exact) — the same matching discipline
/// `AppUninstaller.leftovers` uses, kept consistent so attribution and
/// uninstall agree on who owns what. Read-only; no deletion here.
public enum AppStorageAttribution {
    public static func scan(apps: [InstalledApp]) async -> [AppFootprint] {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appending(path: "Library")
        // Index apps by bundle id and by exact name for fast matching.
        var byBundleID: [String: InstalledApp] = [:]
        var byName: [String: InstalledApp] = [:]
        for app in apps {
            if let id = app.bundleID, !id.isEmpty { byBundleID[id] = app }
            if !app.name.isEmpty { byName[app.name] = app }
        }

        // Scan each bucket directory, matching children to apps. Each task
        // returns its own slice; we merge serially after — no shared mutable
        // state captured into the concurrent tasks.
        let buckets: [(AppFootprint.Bucket, URL)] = [
            (.caches, library.appending(path: "Caches")),
            (.appSupport, library.appending(path: "Application Support")),
            (.containers, library.appending(path: "Containers")),
            (.groupContainers, library.appending(path: "Group Containers")),
            (.logs, library.appending(path: "Logs")),
            (.savedState, library.appending(path: "Saved Application State")),
            (.httpStorages, library.appending(path: "HTTPStorages")),
            (.webKit, library.appending(path: "WebKit")),
            (.preferences, library.appending(path: "Preferences")),
        ]

        // Bundle-id -> app and name -> app are immutable Sendable snapshots
        // safe to capture.
        let snapshot = MatchSnapshot(byBundleID: byBundleID, byName: byName)

        var pathsByApp: [String: [AppFootprint.Path]] = [:]
        await withTaskGroup(of: [(String, AppFootprint.Path)].self) { group in
            for (bucket, dir) in buckets {
                let snap = snapshot
                group.addTask {
                    var slice: [(String, AppFootprint.Path)] = []
                    let children = (try? FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: nil)) ?? []
                    for child in children {
                        let name = child.lastPathComponent
                        guard let app = snap.match(name: name) else { continue }
                        let size = DiskScanner.allocatedSize(of: child)
                        guard size > 0 else { continue }
                        slice.append((app.id, AppFootprint.Path(url: child, bucket: bucket, sizeBytes: size)))
                    }
                    return slice
                }
            }
            for await slice in group {
                for (appID, path) in slice {
                    pathsByApp[appID, default: []].append(path)
                }
            }
        }

        var results: [AppFootprint] = []
        for app in apps {
            let paths = (pathsByApp[app.id] ?? []).sorted { $0.sizeBytes > $1.sizeBytes }
            // Only include apps that actually have attributed library data —
            // apps with zero library footprint don't need an attribution card.
            if !paths.isEmpty {
                results.append(AppFootprint(app: app, paths: paths))
            }
        }
        return results.sorted { $0.totalBytes > $1.totalBytes }
    }
}

/// Immutable, Sendable snapshot of the bundle-id/name → app index, captured
/// safely into the concurrent bucket-scan tasks.
private struct MatchSnapshot: Sendable {
    let byBundleID: [String: InstalledApp]
    let byName: [String: InstalledApp]

    func match(name: String) -> InstalledApp? {
        if let app = byBundleID[name] { return app }
        if let app = byName[name] { return app }
        // Group containers: "<team-id>.<bundle-id>" — anchored suffix match.
        for (id, app) in byBundleID {
            if name == id || name.hasSuffix(".\(id)") { return app }
        }
        return nil
    }
}

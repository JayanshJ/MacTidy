import Foundation

/// An app that is open and works out of folders about to be trashed.
public struct RunningAppConflict: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let appName: String
    public let reason: String
    public var id: String { bundleID }
}

/// An open app as NSWorkspace reports it, as plain values so the guard stays
/// testable.
public struct RunningApp: Sendable, Hashable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Pure: which open apps use the folders in a cleanup. The caller passes the
/// running apps (from NSWorkspace) so this stays testable.
public enum RunningAppGuard {
    struct Rule {
        let bundleID: String
        let name: String
        let paths: [String]   // home-relative prefixes
        let reason: String
    }

    static let rules: [Rule] = [
        Rule(bundleID: "com.apple.dt.Xcode", name: "Xcode",
             paths: ["Library/Developer/Xcode", "Library/Developer/XCTestDevices", "Library/Developer/XCPGDevices",
                     "Library/Caches/org.swift.swiftpm", "Library/Developer/CoreSimulator"],
             reason: "Xcode builds and indexes out of these folders. Quit it first so a build doesn't fail on files that vanished."),
        Rule(bundleID: "com.apple.iphonesimulator", name: "Simulator",
             paths: ["Library/Developer/CoreSimulator", "Library/Developer/Xcode/UserData/Previews"],
             reason: "A running simulator uses these files."),
        Rule(bundleID: "com.google.android.studio", name: "Android Studio",
             paths: [".android/avd", ".gradle", "Library/Android/sdk"],
             reason: "Android Studio and its emulator use these folders while open."),
    ]

    public static func conflicts(for urls: [URL],
                                 runningBundleIDs: Set<String>,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [RunningAppConflict] {
        let homePath = home.standardizedFileURL.path
        let paths = urls.map { $0.standardizedFileURL.path }
        return rules.compactMap { rule in
            guard runningBundleIDs.contains(rule.bundleID) else { return nil }
            let prefixes = rule.paths.map { homePath + "/" + $0 }
            let hit = paths.contains { p in prefixes.contains { p == $0 || p.hasPrefix($0 + "/") } }
            return hit ? RunningAppConflict(bundleID: rule.bundleID, appName: rule.name, reason: rule.reason) : nil
        }
    }

    /// The fixed rules above, plus the owner of anything inside
    /// ~/Library/Application Support: an app writes into its own caches while
    /// it runs, so trashing them then frees nothing and can upset the app.
    /// The owner is matched by known bundle ID, then by bundle ID or name
    /// equal to the folder.
    public static func conflicts(for urls: [URL],
                                 running: [RunningApp],
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [RunningAppConflict] {
        var found = conflicts(for: urls, runningBundleIDs: Set(running.map(\.bundleID)), home: home)
        var seen = Set(found.map(\.bundleID))
        var checkedOwners = Set<String>()
        for url in urls {
            guard let owner = AppSupportRules.ownerIdentity(of: url),
                  checkedOwners.insert(owner.key).inserted else { continue }
            let match = running.first { app in
                owner.bundleIDs.contains(app.bundleID)
                    || app.bundleID.caseInsensitiveCompare(owner.key) == .orderedSame
                    || (!app.name.isEmpty && (app.name.caseInsensitiveCompare(owner.name) == .orderedSame
                        || app.name.caseInsensitiveCompare(owner.key) == .orderedSame))
            }
            guard let app = match, seen.insert(app.bundleID).inserted else { continue }
            let name = app.name.isEmpty ? owner.name : app.name
            found.append(RunningAppConflict(
                bundleID: app.bundleID, appName: name,
                reason: "\(name) keeps files in its folder open while it runs. Quit it first so it rebuilds them cleanly."))
        }
        return found
    }
}

import Foundation

/// An app that is open and works out of folders about to be trashed.
public struct RunningAppConflict: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let appName: String
    public let reason: String
    public var id: String { bundleID }
}

/// Pure: which open apps use the folders in a cleanup. The caller passes the
/// running bundle IDs (from NSWorkspace) so this stays testable.
public enum RunningAppGuard {
    struct Rule {
        let bundleID: String
        let name: String
        let paths: [String]   // home-relative prefixes
        let reason: String
    }

    static let rules: [Rule] = [
        Rule(bundleID: "com.apple.dt.Xcode", name: "Xcode",
             paths: ["Library/Developer/Xcode", "Library/Caches/org.swift.swiftpm", "Library/Developer/CoreSimulator"],
             reason: "Xcode builds and indexes out of these folders. Quit it first so a build doesn't fail on files that vanished."),
        Rule(bundleID: "com.apple.iphonesimulator", name: "Simulator",
             paths: ["Library/Developer/CoreSimulator", "Library/Developer/Xcode/UserData/Previews"],
             reason: "A running simulator uses these files."),
        Rule(bundleID: "com.google.android.studio", name: "Android Studio",
             paths: [".android/avd", ".gradle"],
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
}

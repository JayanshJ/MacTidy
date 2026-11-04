import Foundation

public enum BuildOutput {
    public static let finding = "ignoredBuildOutput"
    public static let xcodeFinding = "xcodeBuildOutput"
    /// A deliberately narrow list. Git-ignored does not imply disposable.
    static let names: Set<String> = ["dist", "out", "build"]

    static func hasSwiftMarker(parent: URL, markers: [String]) -> Bool {
        if markers.contains(where: { FileManager.default.fileExists(atPath: parent.appending(path: $0).path) }) {
            return true
        }
        return markers.contains("Package.swift") && hasXcodeProject(parent)
    }

    static func hasXcodeProject(_ parent: URL) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return children.contains {
            $0.pathExtension == "xcodeproj"
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
    }

    static func isIgnored(_ url: URL) -> Bool {
        guard names.contains(url.lastPathComponent) else { return false }
        let parent = url.deletingLastPathComponent().path
        let args = ["--no-optional-locks", "-C", parent]
        guard Shell.run("/usr/bin/git", args + ["check-ignore", "--quiet", "--", url.lastPathComponent + "/"])?.succeeded == true,
              let tracked = Shell.run("/usr/bin/git", args + ["ls-files", "--", url.lastPathComponent + "/"]),
              tracked.succeeded, tracked.stdout.isEmpty else { return false }
        return true
    }

    /// Cold output first; recent output remains available for explicit review.
    static func rank(_ item: ScanItem, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(item.lastModified ?? now) / 86400)
        return Double(item.sizeBytes) * (0.1 + min(days / 180, 1))
    }
}

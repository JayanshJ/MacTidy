import AppKit
import Foundation

/// The bundle identifiers of the apps on this Mac, for telling an app's data
/// folder from a leftover. Errs towards "owned": a folder counts as an
/// installed app's when it matches the app's identifier, is a helper or
/// shared folder of it (`com.vendor.app.helper`, `com.vendor.shared`), or
/// Launch Services still knows an app with that identifier.
public struct InstalledApps: Sendable {
    let identifiers: Set<String>
    let asksLaunchServices: Bool

    /// `asksLaunchServices` is off in tests, so a fake identifier can't hit
    /// a real app.
    public init(bundleIDs: some Sequence<String>, asksLaunchServices: Bool = false) {
        identifiers = Set(bundleIDs.map { $0.lowercased() })
        self.asksLaunchServices = asksLaunchServices
    }

    public func owns(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if identifiers.contains(id) { return true }
        let vendor = id.split(separator: ".").prefix(2).joined(separator: ".") + "."
        if identifiers.contains(where: { id.hasPrefix($0 + ".") || $0.hasPrefix(vendor) }) { return true }
        guard asksLaunchServices,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Folders apps are installed in. Folders inside them (Utilities,
    /// "Microsoft Office") are looked into one level.
    static func roots(home: URL) -> [URL] {
        ["/Applications", "/System/Applications", "/Applications/Setapp"].map(URL.init(fileURLWithPath:))
            + [home.appending(path: "Applications"),
               home.appending(path: "Library/Application Support/Setapp/Applications")]
    }

    /// Reads every app's Info.plist under the usual roots.
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstalledApps {
        let fm = FileManager.default
        var ids: [String] = []
        func read(_ app: URL) {
            let plist = app.appending(path: "Contents/Info.plist")
            if let info = NSDictionary(contentsOf: plist), let id = info["CFBundleIdentifier"] as? String {
                ids.append(id)
            }
        }
        for root in roots(home: home) {
            for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if entry.pathExtension == "app" {
                    read(entry)
                } else {
                    for nested in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                    where nested.pathExtension == "app" {
                        read(nested)
                    }
                }
            }
        }
        return InstalledApps(bundleIDs: ids, asksLaunchServices: true)
    }
}

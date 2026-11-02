import Foundation

/// Folders in ~/Library/Containers and ~/Library/Group Containers whose app is
/// gone, judged by the same `InstalledApps.owns` logic and 30-day rule as
/// `AppSupportScanner.isLeftover`. Reads names and first-level dates only, and
/// treats anything unreadable as "not a leftover".
///
/// Group Containers are offered, flagged inside their existing category.
/// App Containers are detected but not offered: moving one out of Containers
/// is refused without Full Disk Access (measured), and it hasn't been shown to
/// work with it.
public enum ContainerLeftovers {
    /// macOS's own containers, including the ones not named `com.apple.*`:
    /// Shortcuts is `is.workflow`, the TV app is `tvappservices`, and Podcasts
    /// is `243LU875E5.groups.com.apple.podcasts`.
    public static func isApple(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("com.apple") || lower.contains("is.workflow") || lower.contains("tvappservices")
    }

    /// The app a Group Container names, or nil when that isn't clear. Names
    /// look like `TEAMID.x`, `group.x`, `TEAMID.group.x` or `group.TEAMID.x`,
    /// and only `x` being a full bundle identifier says whose it is:
    /// `UBF8T346G9.Office` and `group.tvappservices.container` don't. Shared
    /// groups stay unclear too: `group.com.facebook.family` belongs to
    /// WhatsApp, a different vendor as far as its name goes.
    static func bundleID(fromGroupName name: String) -> String? {
        var parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "group" || parts.first.map(isTeamID) == true else { return nil }
        if parts.first == "group" { parts.removeFirst() }
        if parts.first.map(isTeamID) == true { parts.removeFirst() }
        if parts.first == "group" { parts.removeFirst() }
        let id = parts.joined(separator: ".")
        guard AppSupportRules.isBundleIdentifier(id),
              let last = parts.last?.lowercased(), last != "family", last != "shared" else { return nil }
        return id
    }

    /// Apple team identifiers are ten uppercase letters and digits.
    static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isNumber || ($0.isUppercase && $0.isASCII) }
    }

    /// A Group Container of an app that's gone: its name says whose it is, no
    /// installed app owns that, and nothing has touched it for a month.
    static func isLeftoverGroup(_ folder: URL, installed: InstalledApps, now: Date) -> Bool {
        let name = folder.lastPathComponent
        guard !isApple(name), let id = bundleID(fromGroupName: name) else { return false }
        return isUntouched(folder, now: now) && !installed.owns(id)
    }

    /// An app Container of an app that's gone. Its name is the bundle
    /// identifier; iOS apps' containers are named by UUID and never match.
    static func isLeftoverContainer(_ folder: URL, installed: InstalledApps, now: Date) -> Bool {
        let name = folder.lastPathComponent
        guard !isApple(name), AppSupportRules.isBundleIdentifier(name) else { return false }
        return isUntouched(folder, now: now) && !installed.owns(name)
    }

    /// App Containers of removed apps. Not offered in the app; see above.
    static func appContainers(in library: URL, installed: InstalledApps, now: Date = Date()) -> [URL] {
        firstLevel(of: library.appending(path: "Containers")).filter {
            isLeftoverContainer($0, installed: installed, now: now)
        }
    }

    private static func isUntouched(_ folder: URL, now: Date) -> Bool {
        guard let modified = AppSupportScanner.newestModification(of: folder) else { return false }
        return now.timeIntervalSince(modified) >= AppSupportScanner.leftoverMinimumAge
    }

    private static func firstLevel(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )) ?? []).filter(AppSupportScanner.isRealDirectory)
    }
}

extension CategoryScanner {
    /// Every Group Container but macOS's own, which can't be trashed. Those of
    /// removed apps are flagged in place, so no byte is listed twice.
    func groupContainerItems(now: Date = Date()) async -> [ScanItem] {
        let installed = installedApps ?? InstalledApps.scan(home: home)
        return await children(of: "Library/Group Containers", .groupContainers)
            .filter { !ContainerLeftovers.isApple($0.url.lastPathComponent) }
            .map { item in
                guard item.isDirectory,
                      ContainerLeftovers.isLeftoverGroup(item.url, installed: installed, now: now) else { return item }
                return ScanItem(url: item.url, sizeBytes: item.sizeBytes, isDirectory: true,
                                category: .groupContainers, detail: AppSupportRules.removedAppsGroup,
                                lastModified: item.lastModified,
                                finding: AppSupportRules.Finding.leftover.rawValue)
            }
    }
}

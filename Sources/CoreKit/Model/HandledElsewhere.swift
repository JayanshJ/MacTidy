import Darwin
import Foundation

/// One big thing MacTidy shows but never offers to trash, because another app
/// or setting is the right way to manage it.
public struct ElsewhereRule: Sendable, Identifiable {
    /// Where the row's button goes.
    public enum Destination: Sendable, Equatable {
        /// MacTidy's own Docker tab.
        case dockerTab
        /// A pane of System Settings.
        case settings(url: String, title: String)
        /// The owning app: a deep link when it has one, else just the app.
        /// Falls back to revealing the folder when the app isn't installed.
        case app(name: String, bundleIDs: [String], deepLink: String? = nil, title: String? = nil)
        /// No app to open (command-line tools): reveal the folder.
        case folder
    }

    /// Stable: saved in scan history and in `ScanItem.finding`.
    public let id: String
    /// Group title on the detail page ("Steam").
    public let owner: String
    /// What it is ("Steam games"), for rows, growth nudges and the Disk Map.
    public let label: String
    /// Home-relative path; a component may hold a `*` wildcard.
    public let pattern: String
    /// What it is and why it's handled elsewhere, in a sentence or two.
    public let explanation: String
    /// Finishes "manage in …" on a Disk Map caption.
    public let managedIn: String
    public let destination: Destination
    /// Each match is a thing of its own (a game, a machine), named by its
    /// folder, and the folder holding them all is managed the same way.
    var listsChildren = false

    var components: [String] { pattern.split(separator: "/").map(String.init) }

    /// These trees are behind macOS privacy checks, which can prompt the user
    /// or refuse without Full Disk Access. They aren't touched without it.
    public var needsFullDiskAccess: Bool {
        Self.protectedRoots.contains { pattern == $0 || pattern.hasPrefix($0 + "/") }
    }

    static let protectedRoots = [
        "Library/Containers", "Library/Group Containers", "Library/Messages", "Library/Mobile Documents",
    ]

    /// The button's words. An app that isn't installed can only be revealed.
    public func buttonTitle(appInstalled: Bool) -> String {
        switch destination {
        case .dockerTab: "Open Docker Tab"
        case .settings(_, let title): title
        case .app(let name, _, _, let title): appInstalled ? title ?? "Open \(name)" : "Show in Finder"
        case .folder: "Show in Finder"
        }
    }

    /// The row's title: the game or machine's own name for per-item rules.
    public func title(for item: ScanItem) -> String {
        listsChildren ? item.url.lastPathComponent : label
    }
}

/// Everything MacTidy knows about what's handled elsewhere. These items are
/// never part of `CategoryResult`s, so totals, preselection, recommendations
/// and scheduled runs can't include them, and their rows have no checkbox.
public enum HandledElsewhere {
    private static let storageSettings = ElsewhereRule.Destination.settings(
        url: "x-apple.systempreferences:com.apple.settings.Storage", title: "Open Storage Settings")
    private static let iCloudSettings = ElsewhereRule.Destination.settings(
        url: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud", title: "Open iCloud Settings")

    public static let rules: [ElsewhereRule] = [
        // Games
        ElsewhereRule(
            id: "steamGames", owner: "Steam", label: "Steam games",
            pattern: "Library/Application Support/Steam/steamapps/common/*",
            explanation: "Games Steam installed. Uninstall them in Steam, under Settings > Storage, so your library stays correct.",
            managedIn: "Steam",
            destination: .app(name: "Steam", bundleIDs: ["com.valvesoftware.steam"],
                              deepLink: "steam://open/settings", title: "Open Steam Settings"),
            listsChildren: true),

        // Virtual machines and container disks
        ElsewhereRule(
            id: "dockerDisk", owner: "Docker", label: "Docker's disk",
            pattern: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            explanation: "Holds every Docker image, container and volume. Trashing the file deletes all of them, so clean up what's inside from the Docker tab.",
            managedIn: "the Docker tab", destination: .dockerTab),
        ElsewhereRule(
            id: "orbstack", owner: "OrbStack", label: "OrbStack's data",
            pattern: "Library/Group Containers/*.dev.orbstack/data",
            explanation: "OrbStack's containers, images and Linux machines. Trashing this folder deletes all of them, so remove what you don't need in OrbStack.",
            managedIn: "OrbStack",
            destination: .app(name: "OrbStack", bundleIDs: ["dev.kdrag0n.MacVirt"])),
        ElsewhereRule(
            id: "utm", owner: "UTM", label: "UTM virtual machines",
            pattern: "Library/Containers/com.utmapp.UTM/Data/Documents/*.utm",
            explanation: "Virtual machines and their disks. Delete the ones you no longer need in UTM.",
            managedIn: "UTM",
            destination: .app(name: "UTM", bundleIDs: ["com.utmapp.UTM"]),
            listsChildren: true),
        ElsewhereRule(
            id: "parallels", owner: "Parallels", label: "Parallels virtual machines",
            pattern: "Parallels",
            explanation: "Virtual machines and their disks. Remove the ones you no longer need in Parallels Desktop.",
            managedIn: "Parallels Desktop",
            destination: .app(name: "Parallels", bundleIDs: ["com.parallels.desktop.console"])),
        ElsewhereRule(
            id: "virtualBox", owner: "VirtualBox", label: "VirtualBox virtual machines",
            pattern: "VirtualBox VMs",
            explanation: "Virtual machines and their disks. Remove the ones you no longer need in VirtualBox.",
            managedIn: "VirtualBox",
            destination: .app(name: "VirtualBox", bundleIDs: ["org.virtualbox.app.VirtualBox"])),
        ElsewhereRule(
            id: "vagrant", owner: "Vagrant", label: "Vagrant boxes",
            pattern: ".vagrant.d/boxes",
            explanation: "Base images Vagrant downloaded. Run vagrant box prune in Terminal to remove old versions.",
            managedIn: "Terminal with vagrant box prune", destination: .folder),
        ElsewhereRule(
            id: "minikube", owner: "minikube", label: "minikube's clusters",
            pattern: ".minikube",
            explanation: "minikube's clusters and cached images. Run minikube delete in Terminal to remove them.",
            managedIn: "Terminal with minikube delete", destination: .folder),
        ElsewhereRule(
            id: "multipass", owner: "Multipass", label: "Multipass virtual machines",
            pattern: "Library/Application Support/multipassd",
            explanation: "Multipass virtual machines. Run multipass delete --purge in Terminal with a machine's name to remove it.",
            managedIn: "Terminal with multipass delete", destination: .folder),

        // Messaging media
        ElsewhereRule(
            id: "messages", owner: "Messages", label: "Messages attachments",
            pattern: "Library/Messages/Attachments",
            explanation: "Photos, videos and files from your conversations. Trashing them here leaves gaps in your chats, so review them in Storage settings, under Messages.",
            managedIn: "Storage settings", destination: storageSettings),
        ElsewhereRule(
            id: "whatsapp", owner: "WhatsApp", label: "WhatsApp media",
            pattern: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media",
            explanation: "Photos and videos from your chats. Clear them in WhatsApp's storage settings, so chats don't show missing files.",
            managedIn: "WhatsApp",
            destination: .app(name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp"])),
        ElsewhereRule(
            id: "telegram", owner: "Telegram", label: "Telegram's data",
            pattern: "Library/Group Containers/*.ru.keepcoder.Telegram",
            explanation: "Your chats' local data, mostly media Telegram can download again. Clear it in Telegram's storage settings.",
            managedIn: "Telegram",
            destination: .app(name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram"])),
        ElsewhereRule(
            id: "telegramDesktop", owner: "Telegram Desktop", label: "Telegram Desktop's media",
            pattern: "Library/Application Support/Telegram Desktop/tdata/user_data",
            explanation: "Media Telegram Desktop saved. It downloads again when needed. Clear it in the app's storage settings.",
            managedIn: "Telegram Desktop",
            destination: .app(name: "Telegram Desktop", bundleIDs: ["com.tdesktop.Telegram"])),

        // iCloud
        ElsewhereRule(
            id: "iCloudDrive", owner: "iCloud Drive", label: "iCloud Drive's local files",
            pattern: "Library/Mobile Documents",
            explanation: "Files iCloud Drive keeps on this Mac. Trashing them here deletes them from iCloud too. To free space, turn on Optimize Mac Storage in iCloud settings.",
            managedIn: "iCloud settings", destination: iCloudSettings),
    ]

    private static let rulesByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })

    public static func rule(id: String) -> ElsewhereRule? { rulesByID[id] }

    /// The rule that listed this item, or nil for an ordinary scan item.
    public static func rule(for item: ScanItem) -> ElsewhereRule? {
        guard item.category == nil, let id = item.finding else { return nil }
        return rulesByID[id]
    }

    /// The rule that manages a path: the path is a match, is inside one, or is
    /// the folder a per-item rule lists (`steamapps/common`).
    public static func rule(
        covering url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ElsewhereRule? {
        guard let parts = relativeComponents(of: url, home: home) else { return nil }
        return rules.first { rule in
            let pattern = rule.components
            if parts.count >= pattern.count { return matches(parts, pattern) }
            return rule.listsChildren && parts.count == pattern.count - 1 && matches(parts, pattern)
        }
    }

    /// Whether a folder directly in ~/Library/Group Containers holds something
    /// handled elsewhere. The Group containers category leaves those out, so
    /// their bytes are listed once, and nobody is offered WhatsApp's whole
    /// container to get rid of its photos.
    static func claimsGroupContainer(_ name: String) -> Bool {
        let parent = ["Library", "Group Containers"]
        return rules.contains { rule in
            let pattern = rule.components
            return pattern.count > 2 && Array(pattern.prefix(2)) == parent && componentMatches(name, pattern[2])
        }
    }

    // MARK: Grouping

    /// One owner's items on the detail page.
    public struct Group: Identifiable, Sendable {
        public let rule: ElsewhereRule
        public let items: [ScanItem]
        public let bytes: Int64
        public var id: String { rule.id }
    }

    /// Biggest first; each group's items biggest first.
    public static func groups(_ items: [ScanItem]) -> [Group] {
        Dictionary(grouping: items) { $0.finding ?? "" }
            .compactMap { id, members -> Group? in
                guard let rule = rulesByID[id] else { return nil }
                return Group(rule: rule, items: members.sorted { $0.sizeBytes > $1.sizeBytes },
                             bytes: members.reduce(0) { $0 + $1.sizeBytes })
            }
            .sorted { ($0.bytes, $1.rule.id) > ($1.bytes, $0.rule.id) }
    }

    /// "Steam, Docker and Messages", or "Steam, Docker, Messages and 2 more".
    public static func summary(_ groups: [Group]) -> String {
        let names = groups.map(\.rule.owner)
        guard names.count > 3 else {
            return names.count < 2 ? names.first ?? ""
                : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }

    // MARK: Matching

    static func componentMatches(_ name: String, _ pattern: String) -> Bool {
        pattern.contains("*") ? fnmatch(pattern, name, 0) == 0 : pattern == name
    }

    private static func matches(_ parts: [String], _ pattern: [String]) -> Bool {
        zip(parts, pattern).allSatisfy { componentMatches($0, $1) }
    }

    /// No filesystem calls: the Disk Map asks for every row on every render.
    /// `/private/var` and `/var` are the same place but compare differently.
    private static func relativeComponents(of url: URL, home: URL) -> [String]? {
        func normalized(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
        let path = normalized(url)
        let root = normalized(home)
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }
}

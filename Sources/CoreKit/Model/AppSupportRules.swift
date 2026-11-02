import Foundation

/// What MacTidy can say about one folder inside ~/Library/Application Support.
public struct AppSupportInsight: Sendable, Equatable {
    /// The app the folder belongs to, for display ("VS Code", "Claude").
    public let owner: String
    /// What the folder is, in a few words ("Compiled script cache").
    public let label: String
    /// What it is and what trashing it costs, in a sentence or two.
    public let explanation: String
    public let risk: Risk
}

/// What MacTidy knows about ~/Library/Application Support. An app's folder
/// there mixes data that must stay (settings, logins, databases, documents)
/// with caches and spare copies that rebuild. These rules name only the
/// second kind; anything they don't name is the app's own data and is never
/// offered. Pure: classification is by path, so a saved scan reloads with the
/// same labels and tiers.
public enum AppSupportRules {
    static let root = "Library/Application Support"

    /// Folders never looked inside: system and iCloud data, device backups
    /// (their own category), and MacTidy's own logs.
    static let skippedOwners: Set<String> = [
        "MobileSync", "com.apple.TCC", "CloudDocs", "FileProvider", "iCloud",
        "AddressBook", "CallHistoryDB", "CallHistoryTransactions", "Knowledge",
        "com.apple.sharedfilelist", "MacTidy",
    ]

    // MARK: Chromium and Electron caches

    /// Chromium (every browser but Safari and Firefox, and every Electron app:
    /// Slack, Discord, VS Code, Claude, Notion…) keeps these rebuildable caches
    /// beside a profile's real data.
    static let chromiumCaches: [String: String] = [
        "Cache": "Web cache",
        "Code Cache": "Compiled script cache",
        "GPUCache": "Graphics cache",
        "DawnCache": "Graphics shader cache",
        "DawnGraphiteCache": "Graphics shader cache",
        "DawnWebGPUCache": "Graphics shader cache",
        "GraphiteDawnCache": "Graphics shader cache",
        "GrShaderCache": "Graphics shader cache",
        "ShaderCache": "Graphics shader cache",
    ]

    /// Entries that mark a folder as a Chromium profile or Electron app root.
    /// A plain folder named `Cache` elsewhere is not assumed to be a cache.
    static let chromiumMarkers: Set<String> = [
        "Code Cache", "GPUCache", "Local Storage", "Session Storage",
        "IndexedDB", "Service Worker", "Local State",
    ]

    /// Browsers (and Notion, which runs its web app the same way) whose
    /// service-worker caches can hold websites' offline copies.
    static let browserOwners: Set<String> = [
        "Google", "Arc", "Dia", "BraveSoftware", "Microsoft Edge", "Vivaldi",
        "Chromium", "com.operasoftware.Opera", "Comet", "Notion",
    ]

    // MARK: Named folders

    struct Named: Sendable {
        enum Kind: Sendable {
            /// The folder itself is the item.
            case whole
            /// Children named like versions; every one but the newest is an item.
            case supersededVersions
        }
        let owner: String
        let path: String
        let kind: Kind
        let label: String
        let risk: Risk
        let explanation: @Sendable (String) -> String
    }

    static let editors = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Antigravity", "Kiro"]

    static let named: [Named] = [
        Named(owner: "Claude", path: "vm_bundles", kind: .whole, label: "Cowork virtual machine", risk: .caution) { _ in
            "The Linux virtual machine Claude's Cowork feature runs in. Claude downloads it again (about 10 GB) the next time you use Cowork, and Cowork history stored inside it is lost. Quit Claude first."
        },
        Named(owner: "Claude", path: "claude-code", kind: .supersededVersions, label: "Older Claude Code version", risk: .safe) { _ in
            "A copy of Claude Code bundled with Claude that a newer version has replaced. Only the newest one is used."
        },
        Named(owner: "Claude", path: "claude-code-vm", kind: .supersededVersions, label: "Older Cowork Claude Code version", risk: .safe) { _ in
            "A copy of Claude Code for Cowork that a newer version has replaced. Only the newest one is used."
        },
        Named(owner: "com.apple.wallpaper", path: "aerials", kind: .whole, label: "Downloaded aerial wallpapers", risk: .caution) { _ in
            "Aerial wallpapers and screen savers macOS has downloaded. Each downloads again the next time it's shown."
        },
        Named(owner: "Spotify", path: "PersistentCache", kind: .whole, label: "Music cache", risk: .caution) { _ in
            "Spotify's music cache. Songs downloaded for offline listening may be kept here too and would download again."
        },
        Named(owner: "Adobe", path: "Common/Media Cache Files", kind: .whole, label: "Media cache", risk: .safe) { _ in
            "Audio and video previews from Premiere Pro and After Effects. Rebuilt when you open a project."
        },
        Named(owner: "Adobe", path: "Common/Media Cache", kind: .whole, label: "Media cache index", risk: .safe) { _ in
            "The index of Adobe's media cache. Rebuilt when you open a project."
        },
        Named(owner: "zoom.us", path: "data/logs", kind: .whole, label: "Logs", risk: .safe) { _ in
            "Zoom's logs from earlier meetings. Only used for troubleshooting."
        },
        webCache("zoom.us", "data/Cache"),
        Named(owner: "zoom.us", path: "data/GPUCache", kind: .whole, label: "Graphics cache", risk: .safe) { _ in
            "Compiled graphics shaders. Zoom rebuilds them automatically."
        },
        Named(owner: "Steam", path: "appcache/httpcache", kind: .whole, label: "Web cache", risk: .safe) { _ in
            "Steam's store and library web cache. Downloaded again as you browse."
        },
        Named(owner: "Steam", path: "steamapps/shadercache", kind: .whole, label: "Game shader cache", risk: .caution) { _ in
            "Precompiled shaders for your games. Steam rebuilds them, but a game can stutter the first time you play it again."
        },
        logs("Steam"),
        Named(owner: "CrashReporter", path: "", kind: .whole, label: "Crash report records", risk: .safe) { _ in
            "Records macOS keeps about app crashes it has already reported."
        },
        Named(owner: "Telegram Desktop", path: "tdata/emoji", kind: .whole, label: "Emoji images", risk: .safe) { _ in
            "Emoji image sets. Telegram downloads them again when needed."
        },
        webCache("Microsoft Teams", "Cache"),
        webCache("Microsoft", "Teams/Cache"),
        webCache("Epic", "EpicGamesLauncher/Saved/webcache"),
        logs("minecraft"),
        webCache("minecraft", "webcache2"),
        crashReports("minecraft", "crash-reports"),
        logs("Blackmagic Design", "DaVinci Resolve/logs"),
        crashReports("Blackmagic Design", "DaVinci Resolve/CrashDumps"),
        Named(owner: "Oracle", path: "Java/Deployment/cache", kind: .whole, label: "Java download cache", risk: .safe) { _ in
            "Files Java Web Start and applets downloaded. Java fetches them again if something still needs them."
        },
        logs("obs-studio"),
        Named(owner: "obs-studio", path: "profiler_data", kind: .whole, label: "Performance recordings", risk: .safe) { _ in
            "Performance measurements OBS Studio saved from earlier sessions. Only used for troubleshooting."
        },
        logs("qBittorrent"),
        logs("itch"),
        logs("Insomnia"),
        logs("HandBrake", "EncodeLogs"),
        logs("CapCut", "Log"),
        logs("Adobe", "CRLogs"),
        Named(owner: "Kodi", path: "userdata/Thumbnails", kind: .whole, label: "Thumbnails", risk: .safe) { _ in
            "Artwork Kodi has cached for your library. Rebuilt as you browse it."
        },
    ] + editors.flatMap { editor in [
        Named(owner: editor, path: "CachedData", kind: .whole, label: "Compiled code cache", risk: .safe) { owner in
            "\(owner)'s cache of compiled editor and extension code. Rebuilt on the next launch."
        },
        Named(owner: editor, path: "CachedExtensionVSIXs", kind: .whole, label: "Downloaded extension packages", risk: .safe) { owner in
            "Installer packages for extensions \(owner) has already installed. Kept only to speed up reinstalls."
        },
        Named(owner: editor, path: "logs", kind: .whole, label: "Logs", risk: .safe) { owner in
            "\(owner)'s logs from earlier sessions. Only used for troubleshooting."
        },
        Named(owner: editor, path: "User/workspaceStorage", kind: .whole, label: "Per-folder state", risk: .caution) { owner in
            "What \(owner) remembers about each folder you've opened: open tabs, extension data and, in AI editors, chat history. Each folder starts fresh after this."
        },
        Named(owner: editor, path: "User/History", kind: .whole, label: "Local file history", risk: .caution) { owner in
            "Earlier versions of files you edited, shown in \(owner)'s Timeline. Your files stay, but you can't go back to those versions."
        },
    ] }

    private static func logs(_ owner: String, _ path: String = "logs") -> Named {
        Named(owner: owner, path: path, kind: .whole, label: "Logs", risk: .safe) { name in
            "\(name)'s logs from earlier sessions. Only used for troubleshooting."
        }
    }

    private static func webCache(_ owner: String, _ path: String) -> Named {
        Named(owner: owner, path: path, kind: .whole, label: "Web cache", risk: .safe) { name in
            "\(name)'s web cache. Downloaded again when needed. Quit \(name) first."
        }
    }

    private static func crashReports(_ owner: String, _ path: String) -> Named {
        Named(owner: owner, path: path, kind: .whole, label: "Crash reports", risk: .safe) { name in
            "Reports from earlier \(name) crashes. Only used for troubleshooting."
        }
    }

    // MARK: Owners

    /// Folder names that don't read as the app's name. Two-component keys win
    /// over one (Google/Chrome is Chrome; the rest of Google is Drive and more).
    static let ownerNames: [String: String] = [
        "Code": "VS Code", "Code - Insiders": "VS Code Insiders",
        "zoom.us": "Zoom", "discord": "Discord", "obsidian": "Obsidian",
        "com.apple.wallpaper": "Wallpapers", "CrashReporter": "macOS",
        "Google/Chrome": "Google Chrome", "Google/Chrome Beta": "Google Chrome Beta",
        "BraveSoftware/Brave-Browser": "Brave", "com.operasoftware.Opera": "Opera",
        "Telegram Desktop": "Telegram", "Microsoft/Teams": "Microsoft Teams",
        "Epic/EpicGamesLauncher": "Epic Games Launcher", "minecraft": "Minecraft",
        "Blackmagic Design/DaVinci Resolve": "DaVinci Resolve", "Oracle/Java": "Java",
        "obs-studio": "OBS Studio", "itch": "itch.io",
    ]

    /// Bundle identifiers of the app owning a folder, for the running-app
    /// check. Apps whose name matches the folder need no entry.
    static let ownerBundleIDs: [String: [String]] = [
        "Claude": ["com.anthropic.claudefordesktop"],
        "Code": ["com.microsoft.VSCode"], "Code - Insiders": ["com.microsoft.VSCodeInsiders"],
        "Cursor": ["com.todesktop.230313mzl4w4u92"], "Windsurf": ["com.exafunction.windsurf"],
        "VSCodium": ["com.vscodium"],
        "Google/Chrome": ["com.google.Chrome"], "Google/Chrome Beta": ["com.google.Chrome.beta"],
        "BraveSoftware/Brave-Browser": ["com.brave.Browser"],
        "Microsoft Edge": ["com.microsoft.edgemac"], "Arc": ["company.thebrowser.Browser"],
        "Dia": ["company.thebrowser.dia"], "Vivaldi": ["com.vivaldi.Vivaldi"],
        "Slack": ["com.tinyspeck.slackmacgap"], "discord": ["com.hnc.Discord"],
        "Spotify": ["com.spotify.client"], "zoom.us": ["us.zoom.xos"], "Notion": ["notion.id"],
        "Figma": ["com.figma.Desktop"], "Steam": ["com.valvesoftware.steam"],
        "obsidian": ["md.obsidian"], "Signal": ["org.whispersystems.signal-desktop"],
        "Postman": ["com.postmanlabs.mac"], "Microsoft Teams": ["com.microsoft.teams", "com.microsoft.teams2"],
        "Microsoft/Teams": ["com.microsoft.teams", "com.microsoft.teams2"],
        "Codex": ["com.openai.codex"],
    ]

    /// The owner key (one or two leading components) of a path relative to
    /// Application Support.
    static func ownerKey(_ components: [String]) -> String? {
        guard let first = components.first else { return nil }
        if components.count > 1 {
            let two = first + "/" + components[1]
            if ownerNames[two] != nil || ownerBundleIDs[two] != nil { return two }
        }
        return first
    }

    static func ownerName(_ key: String) -> String {
        ownerNames[key] ?? key
    }

    /// Path components below ~/Library/Application Support, or nil when the
    /// URL isn't inside it.
    static func components(of url: URL) -> [String]? {
        let path = url.standardizedFileURL.path
        guard let range = path.range(of: "/" + root + "/") else { return nil }
        let rest = path[range.upperBound...]
        let parts = rest.split(separator: "/").map(String.init)
        return parts.isEmpty ? nil : parts
    }

    /// Where the folder sits inside Application Support, for display
    /// ("Claude › Partitions › preview › Cache").
    public static func displayPath(of url: URL) -> String? {
        components(of: url)?.joined(separator: " › ")
    }

    /// The owning app of a folder inside Application Support, for display.
    public static func owner(of url: URL) -> String? {
        components(of: url).flatMap(ownerKey).map(ownerName)
    }

    /// Bundle identifiers to check before trashing something inside the
    /// folder, plus the owner key for matching running apps by name.
    static func ownerIdentity(of url: URL) -> (key: String, name: String, bundleIDs: [String])? {
        guard let parts = components(of: url), let key = ownerKey(parts) else { return nil }
        return (key, ownerName(key), ownerBundleIDs[key] ?? [])
    }

    // MARK: Findings

    /// What the scanner learned that the path alone can't show. Stored in
    /// `ScanItem.finding`.
    public enum Finding: String, Sendable {
        /// A whole folder of an app that isn't installed anymore.
        case leftover
        /// A version kept beside a newer sibling version.
        case olderVersion
        /// A virtual machine's disk image.
        case virtualDisk
    }

    /// Group title (`ScanItem.detail`) for leftovers of removed apps.
    public static let removedAppsGroup = "Apps no longer installed"

    /// A folder MacTidy has nothing to say about, the kind "Why is this big?"
    /// is for.
    public static func isUnrecognized(_ item: ScanItem) -> Bool {
        item.isDirectory && insight(for: item) == nil
    }

    /// The item's finding, if any, else what its path says.
    public static func insight(for item: ScanItem) -> AppSupportInsight? {
        guard let finding = item.finding.flatMap(Finding.init) else { return insight(for: item.url) }
        let folder = item.url.lastPathComponent
        switch finding {
        case .leftover:
            return AppSupportInsight(
                owner: removedAppsGroup, label: "Leftover app data",
                explanation: "Data from \(folder), an app that isn't installed on this Mac and hasn't touched this folder in over a month. Nothing uses it unless you reinstall that app.",
                risk: .caution)
        case .olderVersion:
            let owner = item.detail ?? owner(of: item.url) ?? folder
            return AppSupportInsight(
                owner: owner, label: "Older version",
                explanation: "\(owner) keeps this version next to a newer one. Usually only the newest is used, so this is a leftover from an update. Check the app still works after trashing it.",
                risk: .caution)
        case .virtualDisk:
            let owner = item.detail ?? owner(of: item.url) ?? folder
            return AppSupportInsight(
                owner: owner, label: "Virtual machine disk",
                explanation: "A virtual machine's disk inside \(owner)'s folder. Trashing it deletes that machine and everything installed in it.",
                risk: .danger)
        }
    }

    // MARK: Classification

    /// What MacTidy knows about this folder, or nil when it is the app's own
    /// data (or not inside Application Support at all).
    public static func insight(for url: URL) -> AppSupportInsight? {
        guard let parts = components(of: url), let key = ownerKey(parts) else { return nil }
        let owner = ownerName(key)
        let relative = parts.dropFirst().joined(separator: "/")

        for rule in named where rule.owner == parts[0] {
            switch rule.kind {
            case .whole where relative == rule.path:
                return AppSupportInsight(owner: owner, label: rule.label,
                                         explanation: rule.explanation(owner), risk: rule.risk)
            case .supersededVersions where parts.count >= 2:
                let parent = parts.dropFirst().dropLast().joined(separator: "/")
                if parent == rule.path, isVersion(parts[parts.count - 1]) {
                    return AppSupportInsight(owner: owner, label: rule.label,
                                             explanation: rule.explanation(owner), risk: rule.risk)
                }
            default:
                continue
            }
        }

        let name = parts[parts.count - 1]
        if name == "CacheStorage", parts.count >= 2, parts[parts.count - 2] == "Service Worker" {
            if browserOwners.contains(parts[0]) {
                return AppSupportInsight(
                    owner: owner, label: "Offline website cache",
                    explanation: "Files websites saved in \(owner) through service workers. Some sites keep offline copies here and download them again. Logins and history aren't affected.",
                    risk: .caution)
            }
            return AppSupportInsight(
                owner: owner, label: "Offline web cache",
                explanation: "Files \(owner)'s built-in web pages saved for offline use. Downloaded again when needed. Quit \(owner) first.",
                risk: .safe)
        }
        if parts.count >= 2, let label = chromiumCaches[name] {
            let explanation = switch name {
            case "Cache":
                "\(owner)'s web cache. \(owner) downloads what it needs again. Quit \(owner) first so it starts a fresh one."
            case "Code Cache":
                "Compiled JavaScript \(owner) keeps to start faster. Rebuilt automatically; the next launch can be slightly slower."
            default:
                "Compiled graphics shaders. \(owner) rebuilds them automatically."
            }
            return AppSupportInsight(owner: owner, label: label, explanation: explanation, risk: .safe)
        }
        return nil
    }

    static func isVersion(_ name: String) -> Bool {
        guard name.first?.isNumber == true else { return false }
        return !UpdateChecker.Version(name).numeric.isEmpty
    }

    /// Stricter, for folders no rule names: a dotted version ("1.4.2"), so
    /// year folders ("2024") and plain numbers aren't taken for versions.
    static func isDottedVersion(_ name: String) -> Bool {
        isVersion(name) && name.contains(".") && UpdateChecker.Version(name).numeric.count >= 2
    }

    /// An app bundle identifier as a folder name: three or more dot-separated
    /// parts ("com.vendor.app").
    static func isBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}

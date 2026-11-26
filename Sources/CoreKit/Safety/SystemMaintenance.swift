import Foundation

// MARK: - Curated macOS Maintenance ShellActions

public struct ResetQuickLookCacheAction: ShellAction {
    public let id = UUID()
    public var displayName: String { "Reset Quick Look cache" }
    public var commandSummary: String { "qlmanage -r && qlmanage -r cache" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init() {}

    public func run() -> Shell.Output? {
        let first = Shell.run("/usr/bin/qlmanage", ["-r"])
        let second = Shell.run("/usr/bin/qlmanage", ["-r", "cache"])
        return second ?? first
    }
}

public struct ClearFontCacheAction: ShellAction {
    public let id = UUID()
    public var displayName: String { "Reset user font caches" }
    public var commandSummary: String { "atsutil databases -removeUser" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init() {}

    public func run() -> Shell.Output? {
        Shell.run("/usr/bin/atsutil", ["databases", "-removeUser"])
    }
}

public struct RestartFinderAction: ShellAction {
    public let id = UUID()
    public var displayName: String { "Restart Finder" }
    public var commandSummary: String { "killall Finder" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init() {}

    public func run() -> Shell.Output? {
        Shell.run("/usr/bin/killall", ["Finder"])
    }
}

public struct RestartDockAction: ShellAction {
    public let id = UUID()
    public var displayName: String { "Restart Dock" }
    public var commandSummary: String { "killall Dock" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init() {}

    public func run() -> Shell.Output? {
        Shell.run("/usr/bin/killall", ["Dock"])
    }
}

public struct RebuildSpotlightIndexAction: ShellAction {
    public let id = UUID()
    public var displayName: String { "Rebuild Spotlight index (/)" }
    public var commandSummary: String { "sudo mdutil -E /" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init() {}

    public func run() -> Shell.Output? {
        let script = "do shell script \"/usr/bin/mdutil -E /\" with administrator privileges"
        guard let out = Shell.run("/usr/bin/osascript", ["-e", script]) else { return nil }
        if !out.succeeded {
            let msg = (out.stderr.contains("User canceled") || out.stderr.contains("-128"))
                ? "Administrator permission was cancelled."
                : Shell.humanReadableAppleScriptError(out.stderr.isEmpty ? out.stdout : out.stderr)
            return Shell.Output(stdout: out.stdout, stderr: msg, exitCode: out.exitCode)
        }
        return out
    }
}

public struct ThinTimeMachineSnapshotsAction: ShellAction {
    public let id = UUID()
    public let targetBytes: Int64
    public var displayName: String { "Thin Time Machine local snapshots" }
    public var commandSummary: String { "tmutil thinlocalsnapshots / \(targetBytes) 4" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init(targetBytes: Int64 = 10_000_000_000) {
        self.targetBytes = targetBytes
    }

    public func run() -> Shell.Output? {
        Shell.run("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "\(targetBytes)", "4"])
    }
}

// MARK: - Reversible System Tweaks (macOS `defaults`)

public struct SystemTweak: Identifiable, Sendable, Equatable {
    public enum Category: String, CaseIterable, Sendable {
        case finder = "Finder"
        case dock = "Dock"
        case screenshots = "Screenshots"
        case keyboard = "Keyboard"
    }

    public enum Kind: Sendable, Equatable {
        case bool(defaultValue: Bool)
        case choice(options: [ChoiceOption], defaultValue: String)
    }

    public struct ChoiceOption: Identifiable, Sendable, Equatable {
        public let label: String
        public let value: String
        public let defaultsType: DefaultsValueType
        public var id: String { value }

        public init(label: String, value: String, defaultsType: DefaultsValueType) {
            self.label = label
            self.value = value
            self.defaultsType = defaultsType
        }
    }

    public enum DefaultsValueType: String, Sendable, Equatable {
        case string = "-string"
        case float = "-float"
    }

    public let id: String
    public let category: Category
    public let title: String
    public let subtitle: String
    public let domain: String
    public let key: String
    public let kind: Kind
    public let restartTarget: String?

    public init(
        id: String,
        category: Category,
        title: String,
        subtitle: String,
        domain: String,
        key: String,
        kind: Kind,
        restartTarget: String?
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.domain = domain
        self.key = key
        self.kind = kind
        self.restartTarget = restartTarget
    }

    public func writeCommandPreview(boolValue: Bool) -> String {
        let base = "defaults write \(domain) \(key) -bool \(boolValue ? "true" : "false")"
        if let target = restartTarget { return "\(base) && killall \(target)" }
        return base
    }

    public func writeCommandPreview(option: ChoiceOption) -> String {
        let base = "defaults write \(domain) \(key) \(option.defaultsType.rawValue) \(option.value)"
        if let target = restartTarget { return "\(base) && killall \(target)" }
        return base
    }

    public var resetCommandPreview: String {
        let base = "defaults delete \(domain) \(key)"
        if let target = restartTarget { return "\(base) && killall \(target)" }
        return base
    }
}

public struct SystemTweakState: Identifiable, Sendable, Equatable {
    public let tweak: SystemTweak
    public let rawValue: String?
    public var id: String { tweak.id }
    public var isCustomized: Bool { rawValue != nil }

    public init(tweak: SystemTweak, rawValue: String?) {
        self.tweak = tweak
        self.rawValue = rawValue
    }

    public var boolValue: Bool {
        guard case .bool(let defaultValue) = tweak.kind else { return false }
        return SystemTweaks.parseBool(rawValue) ?? defaultValue
    }

    public var selectedChoiceValue: String {
        guard case .choice(let options, let defaultValue) = tweak.kind else { return "" }
        guard let rawValue else { return defaultValue }
        if let floatMatch = options.first(where: {
            $0.defaultsType == .float && Double($0.value) == Double(rawValue)
        }) {
            return floatMatch.value
        }
        return options.first(where: { $0.value == rawValue })?.value ?? defaultValue
    }
}

public enum SystemTweaks {
    public static let catalog: [SystemTweak] = [
        SystemTweak(
            id: "finder-extensions",
            category: .finder,
            title: "Show all filename extensions",
            subtitle: "Displays .json, .swift, .png, etc. across Finder and Open/Save panels.",
            domain: "NSGlobalDomain",
            key: "AppleShowAllExtensions",
            kind: .bool(defaultValue: false),
            restartTarget: "Finder"
        ),
        SystemTweak(
            id: "finder-hidden-files",
            category: .finder,
            title: "Show hidden files in Finder",
            subtitle: "Shows dotfiles like .env, .gitignore, and ~/Library without pressing ⌘⇧.",
            domain: "com.apple.finder",
            key: "AppleShowAllFiles",
            kind: .bool(defaultValue: false),
            restartTarget: "Finder"
        ),
        SystemTweak(
            id: "finder-path-bar",
            category: .finder,
            title: "Show Finder path bar",
            subtitle: "Displays the clickable breadcrumb bar at the bottom of Finder windows.",
            domain: "com.apple.finder",
            key: "ShowPathbar",
            kind: .bool(defaultValue: false),
            restartTarget: "Finder"
        ),
        SystemTweak(
            id: "finder-folders-first",
            category: .finder,
            title: "Keep folders on top when sorting by name",
            subtitle: "Lists folders before files in Finder windows.",
            domain: "com.apple.finder",
            key: "_FXSortFoldersFirst",
            kind: .bool(defaultValue: false),
            restartTarget: "Finder"
        ),
        SystemTweak(
            id: "dsstore-network",
            category: .finder,
            title: "Avoid .DS_Store on network volumes",
            subtitle: "Prevents Finder from creating .DS_Store files on SMB/NFS shares.",
            domain: "com.apple.desktopservices",
            key: "DSDontWriteNetworkStores",
            kind: .bool(defaultValue: false),
            restartTarget: nil
        ),
        SystemTweak(
            id: "dsstore-usb",
            category: .finder,
            title: "Avoid .DS_Store on USB drives",
            subtitle: "Prevents Finder from creating .DS_Store files on external/removable disks.",
            domain: "com.apple.desktopservices",
            key: "DSDontWriteUSBStores",
            kind: .bool(defaultValue: false),
            restartTarget: nil
        ),
        SystemTweak(
            id: "dock-autohide-delay",
            category: .dock,
            title: "Dock auto-hide delay",
            subtitle: "Controls how quickly the Dock appears when auto-hide is turned on.",
            domain: "com.apple.dock",
            key: "autohide-delay",
            kind: .choice(
                options: [
                    .init(label: "Default (0.5s)", value: "0.5", defaultsType: .float),
                    .init(label: "Fast (0.15s)", value: "0.15", defaultsType: .float),
                    .init(label: "Instant (0s)", value: "0", defaultsType: .float),
                ],
                defaultValue: "0.5"
            ),
            restartTarget: "Dock"
        ),
        SystemTweak(
            id: "dock-static-only",
            category: .dock,
            title: "Show only open apps in Dock",
            subtitle: "Hides pinned icons so the Dock acts like a clean task switcher.",
            domain: "com.apple.dock",
            key: "static-only",
            kind: .bool(defaultValue: false),
            restartTarget: "Dock"
        ),
        SystemTweak(
            id: "screenshot-format",
            category: .screenshots,
            title: "Screenshot file format",
            subtitle: "Image format used by ⌘⇧3 / ⌘⇧4 / ⌘⇧5.",
            domain: "com.apple.screencapture",
            key: "type",
            kind: .choice(
                options: [
                    .init(label: "PNG (Default)", value: "png", defaultsType: .string),
                    .init(label: "JPEG", value: "jpg", defaultsType: .string),
                    .init(label: "WebP", value: "webp", defaultsType: .string),
                    .init(label: "PDF", value: "pdf", defaultsType: .string),
                ],
                defaultValue: "png"
            ),
            restartTarget: "SystemUIServer"
        ),
        SystemTweak(
            id: "screenshot-thumbnail",
            category: .screenshots,
            title: "Show floating screenshot thumbnail",
            subtitle: "Turn off to save screenshots directly without the bottom-right preview delay.",
            domain: "com.apple.screencapture",
            key: "show-thumbnail",
            kind: .bool(defaultValue: true),
            restartTarget: "SystemUIServer"
        ),
        SystemTweak(
            id: "keyboard-press-and-hold",
            category: .keyboard,
            title: "Press-and-hold accent picker",
            subtitle: "Turn off to enable continuous key repeat when holding keys in editors/terminals.",
            domain: "NSGlobalDomain",
            key: "ApplePressAndHoldEnabled",
            kind: .bool(defaultValue: true),
            restartTarget: nil
        ),
    ]

    public typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> Shell.Output?

    public static func parseBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    public static func readAll(runner: CommandRunner = { Shell.run($0, $1) }) -> [SystemTweakState] {
        catalog.map { tweak in
            let out = runner("/usr/bin/defaults", ["read", tweak.domain, tweak.key])
            let raw: String? = if let out, out.succeeded {
                out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                nil
            }
            return SystemTweakState(tweak: tweak, rawValue: raw)
        }
    }

    @discardableResult
    public static func setBool(
        _ value: Bool,
        for tweak: SystemTweak,
        runner: CommandRunner = { Shell.run($0, $1) }
    ) -> Bool {
        guard let out = runner("/usr/bin/defaults", [
            "write", tweak.domain, tweak.key, "-bool", value ? "true" : "false",
        ]), out.succeeded else {
            return false
        }
        if let target = tweak.restartTarget {
            _ = runner("/usr/bin/killall", [target])
        }
        return true
    }

    @discardableResult
    public static func setChoice(
        _ option: SystemTweak.ChoiceOption,
        for tweak: SystemTweak,
        runner: CommandRunner = { Shell.run($0, $1) }
    ) -> Bool {
        guard let out = runner("/usr/bin/defaults", [
            "write", tweak.domain, tweak.key, option.defaultsType.rawValue, option.value,
        ]), out.succeeded else {
            return false
        }
        if let target = tweak.restartTarget {
            _ = runner("/usr/bin/killall", [target])
        }
        return true
    }

    @discardableResult
    public static func reset(
        _ tweak: SystemTweak,
        runner: CommandRunner = { Shell.run($0, $1) }
    ) -> Bool {
        // `defaults delete` exits non-zero when the key is already absent,
        // which still leaves it at the macOS default.
        let out = runner("/usr/bin/defaults", ["delete", tweak.domain, tweak.key])
        let ok = out.map { $0.succeeded || $0.stderr.contains("not found") || $0.stderr.contains("does not exist") } ?? false
        if ok, let target = tweak.restartTarget {
            _ = runner("/usr/bin/killall", [target])
        }
        return ok
    }
}

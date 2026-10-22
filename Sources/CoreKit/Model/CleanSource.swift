import Foundation

/// How much trashing an item costs the user. Drives per-item preselection and
/// the row badge. Everything still goes to the Trash, so every tier is undoable;
/// the tier is about what's lost *until* the user notices and restores.
public enum Risk: String, Sendable {
    /// Regenerates on demand (logs, caches). Safe to preselect.
    case safe
    /// Costs a re-download, an uninstall, or lost history (transcripts,
    /// models, installed plugins). Listed, never preselected.
    case caution
    /// Loses state that is slow or impossible to rebuild (VM disks holding
    /// every container and image). Listed, never preselected.
    case danger

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .caution: "Caution"
        case .danger: "Danger"
        }
    }
}

/// One declarative cleanup source: a home-relative path, the category it is
/// listed under, and its risk. Adding a cache MacTidy should know about is one
/// line here. Sources never bypass the destructive pipeline: their items are
/// plain `ScanItem`s that go `DeletionPlan → SafePathPolicy → Trasher`.
public struct CleanSource: Sendable {
    public enum Locate: Sendable {
        /// The directory is one item.
        case whole
        /// Each child is its own item (per project, per model, per skill), so
        /// the user can keep some. Children that are, or contain, another
        /// source's path are skipped so no byte is counted twice.
        case children
    }

    public let category: Category
    public let path: String
    public let label: String
    public let risk: Risk
    public let locate: Locate

    init(_ category: Category, _ path: String, _ label: String,
         _ risk: Risk = .safe, _ locate: Locate = .whole) {
        self.category = category
        self.path = path
        self.label = label
        self.risk = risk
        self.locate = locate
    }
}

extension CleanSource {
    public static let all: [CleanSource] = userCaches + devCaches + aiAgents

    /// ~/Library/Caches, one item per app. Children claimed by a more specific
    /// source below (SwiftPM, pip, Playwright…) are skipped here.
    static let userCaches: [CleanSource] = [
        .init(.userCaches, "Library/Caches", "", .safe, .children),
    ]

    /// Package-manager and tool caches outside ~/Library/Caches (that folder
    /// is the userCaches category; listing its children here would double-count).
    static let devCaches: [CleanSource] = [
        .init(.devCaches, ".npm", "npm cache"),
        .init(.devCaches, ".cargo/registry", "Cargo registry"),
        .init(.devCaches, ".gradle/caches", "Gradle caches"),
        .init(.devCaches, ".gradle/wrapper/dists", "Gradle wrapper distributions"),
        .init(.devCaches, "Library/pnpm/store", "pnpm store"),
        .init(.devCaches, "go/pkg/mod", "Go module cache"),
        .init(.devCaches, ".m2/repository", "Maven repository"),
        .init(.devCaches, ".yarn/cache", "Yarn cache"),
        .init(.devCaches, ".terraform.d/plugin-cache", "Terraform plugin cache"),
        .init(.devCaches, ".sbt", "sbt cache"),
        .init(.devCaches, ".coursier/cache", "Coursier cache"),
        .init(.devCaches, ".bun/install/cache", "Bun cache"),
        // Per child, so AI-agent entries that live in ~/.cache (codex runtimes,
        // Hugging Face) are skipped here and listed once under aiAgents.
        .init(.devCaches, ".cache", "XDG cache (~/.cache)", .safe, .children),
        .init(.devCaches, ".deno", "Deno cache"),
        .init(.devCaches, "Library/Developer/Xcode/iOS DeviceLogs", "iOS Device Logs"),
        .init(.devCaches, ".cocoapods", "CocoaPods cache"),
        .init(.devCaches, ".fastlane", "Fastlane cache"),
        .init(.devCaches, ".colima", "Colima VM disk", .danger),
        .init(.devCaches, ".lima", "Lima VM disk", .danger),
        .init(.devCaches, ".vscode/extensions", "VS Code extensions", .caution),
        .init(.devCaches, ".android/avd", "Android AVD data", .caution),
        .init(.devCaches, ".android/cache", "Android SDK cache"),
        // Per child, so Previews (regenerable, often GBs) is listed on its own
        // while schemes, snippets and key bindings stay Caution.
        .init(.devCaches, "Library/Developer/Xcode/UserData", "Xcode UserData", .caution, .children),

        // Xcode and Apple platforms
        .init(.devCaches, "Library/Developer/Xcode/UserData/Previews", "SwiftUI preview simulators"),
        .init(.devCaches, "Library/Developer/Xcode/Products", "Xcode build products"),
        .init(.devCaches, "Library/Developer/Xcode/watchOS DeviceSupport", "watchOS device symbols", .safe, .children),
        .init(.devCaches, "Library/Developer/Xcode/tvOS DeviceSupport", "tvOS device symbols", .safe, .children),
        .init(.devCaches, "Library/Developer/Xcode/visionOS DeviceSupport", "visionOS device symbols", .safe, .children),
        .init(.devCaches, "Library/Caches/org.swift.swiftpm", "Swift Package Manager cache"),
        .init(.devCaches, "Library/Caches/CocoaPods", "CocoaPods download cache"),
        .init(.devCaches, "Library/Caches/org.carthage.CarthageKit", "Carthage cache"),

        // Python
        .init(.devCaches, "Library/Caches/pip", "pip cache"),
        .init(.devCaches, ".cache/pip", "pip cache"),
        .init(.devCaches, ".cache/uv", "uv cache"),
        .init(.devCaches, "Library/Caches/pypoetry", "Poetry cache"),
        .init(.devCaches, ".conda/pkgs", "conda package cache"),
        .init(.devCaches, "miniconda3/pkgs", "conda package cache"),
        .init(.devCaches, "anaconda3/pkgs", "conda package cache"),
        .init(.devCaches, ".pyenv/versions", "pyenv Python version (reinstall needed)", .caution, .children),

        // Go, Rust, Dart, JS
        .init(.devCaches, "Library/Caches/go-build", "Go build cache"),
        .init(.devCaches, ".cargo/git", "Cargo git checkouts"),
        .init(.devCaches, ".rustup/toolchains", "Rust toolchain (reinstall needed)", .caution, .children),
        .init(.devCaches, ".pub-cache", "Dart and Flutter package cache"),
        .init(.devCaches, "Library/Caches/Yarn", "Yarn cache"),
        .init(.devCaches, ".nvm/.cache", "nvm download cache"),
        .init(.devCaches, ".cache/node-gyp", "node-gyp headers"),
        .init(.devCaches, "Library/Caches/electron", "Electron downloads"),

        // Test browsers and IDEs
        .init(.devCaches, "Library/Caches/ms-playwright", "Playwright browser", .safe, .children),
        .init(.devCaches, ".cache/puppeteer", "Puppeteer browsers"),
        .init(.devCaches, "Library/Caches/Cypress", "Cypress binary", .safe, .children),
        .init(.devCaches, "Library/Caches/JetBrains", "JetBrains IDE cache (re-indexes on open)", .safe, .children),
    ]

    /// AI coding agents and local model stores. Credentials and settings in
    /// these trees are on SafePathPolicy's hard denylist; nothing here can
    /// reach them, and the whole agent folder can never be trashed.
    static let aiAgents: [CleanSource] = [
        // Claude Code
        .init(.aiAgents, ".claude/debug", "Claude Code debug logs"),
        .init(.aiAgents, ".claude/shell-snapshots", "Claude Code shell snapshots"),
        .init(.aiAgents, ".claude/telemetry", "Claude Code telemetry queue"),
        .init(.aiAgents, ".claude/cache", "Claude Code cache"),
        .init(.aiAgents, ".claude/projects", "Claude Code transcripts (needed for --resume)", .caution, .children),
        .init(.aiAgents, ".claude/file-history", "Claude Code rewind history", .caution),
        .init(.aiAgents, ".claude/plugins/cache", "Claude Code plugin (trashing uninstalls)", .caution, .children),
        .init(.aiAgents, ".claude/skills", "Claude Code skill (trashing uninstalls)", .caution, .children),
        // Codex
        .init(.aiAgents, ".codex/cache", "Codex cache"),
        .init(.aiAgents, ".codex/sessions", "Codex session transcripts", .caution, .children),
        .init(.aiAgents, ".codex/archived_sessions", "Codex archived sessions", .caution),
        .init(.aiAgents, ".codex/worktrees", "Codex worktree (may hold unmerged work)", .caution, .children),
        .init(.aiAgents, ".codex/packages", "Codex app packages (re-downloaded)", .caution),
        .init(.aiAgents, ".codex/plugins/cache", "Codex plugin (trashing uninstalls)", .caution, .children),
        .init(.aiAgents, ".cache/codex-runtimes", "Codex runtimes (re-downloaded)", .caution),
        // Other agents
        .init(.aiAgents, ".gemini/tmp", "Gemini CLI chats and checkpoints", .caution),
        .init(.aiAgents, ".cursor/extensions", "Cursor extensions (reinstall needed)", .caution),
        .init(.aiAgents, ".continue/index", "Continue code index (rebuilt)"),
        .init(.aiAgents, ".aider/caches", "Aider cache"),
        // Local models: big, slow to re-pull. Ollama is one store (blobs are
        // shared between models), so it is one item, never split.
        .init(.aiAgents, ".ollama/models", "Ollama models (re-pull needed)", .caution),
        .init(.aiAgents, ".cache/huggingface/hub", "Hugging Face model (re-download needed)", .caution, .children),
        .init(.aiAgents, ".lmstudio/models", "LM Studio models (re-download needed)", .caution, .children),
    ]

    /// The source an item was found by. Matched on the path tail so it works
    /// for any home directory (tests use a fake one). Whole-dir sources match
    /// on path alone, so items restored from an older saved scan (e.g. Ollama
    /// models once listed under devCaches) still get today's risk tier.
    public static func source(for item: ScanItem) -> CleanSource? {
        let path = item.url.path
        let parent = item.url.deletingLastPathComponent().path
        // Most specific wins: Xcode/UserData/Previews (its own source) beats
        // the per-child Xcode/UserData source that also matches it.
        return all.filter { source in
            let tail = "/" + source.path
            switch source.locate {
            case .whole: return path.hasSuffix(tail)
            case .children: return item.category == source.category && parent.hasSuffix(tail)
            }
        }
        .max { $0.path.count < $1.path.count }
    }
}

extension ScanItem {
    /// Risk of the registry source this item came from; items from bespoke
    /// scanners are judged at category level and report `.safe`.
    public var risk: Risk { CleanSource.source(for: self)?.risk ?? .safe }

    /// Whether bulk "select safe" and scheduled runs may include this item:
    /// its category must be preselectable *and* the item itself safe.
    public var isPreselectable: Bool {
        (category?.isPreselectable ?? false) && risk == .safe
    }
}

extension CategoryScanner {
    /// Scans every registry source in `category`, in parallel.
    func registryItems(_ category: Category) async -> [ScanItem] {
        let home = self.home
        // Both sides normalized the same way: listings return /private/var/…
        // while resolvingSymlinksInPath maps that back to /var/….
        let allRoots = CleanSource.all.map { home.appending(path: $0.path).resolvingSymlinksInPath().path }
        return await withTaskGroup(of: [ScanItem].self) { group in
            for source in CleanSource.all where source.category == category {
                group.addTask { await Self.scan(source, home: home, allRoots: allRoots) }
            }
            var items: [ScanItem] = []
            for await batch in group { items += batch }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    private static func scan(_ source: CleanSource, home: URL, allRoots: [String]) async -> [ScanItem] {
        let url = home.appending(path: source.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        switch source.locate {
        case .whole:
            let size = DiskScanner.allocatedSize(of: url)
            guard size > 0 else { return [] }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return [ScanItem(url: url, sizeBytes: size, isDirectory: true,
                             category: source.category, detail: source.label.isEmpty ? nil : source.label,
                             lastModified: modified)]
        case .children:
            return await DiskScanner.topLevelScan(root: url, category: source.category)
                .filter { child in
                    let p = child.url.resolvingSymlinksInPath().path
                    return child.sizeBytes > 0
                        && !allRoots.contains { $0 == p || $0.hasPrefix(p + "/") }
                }
                .map { ScanItem(url: $0.url, sizeBytes: $0.sizeBytes, isDirectory: $0.isDirectory,
                                category: source.category, detail: source.label.isEmpty ? nil : source.label,
                                lastModified: $0.lastModified) }
        }
    }
}

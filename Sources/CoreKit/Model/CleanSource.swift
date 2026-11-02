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
    public enum Locate: Sendable, Equatable {
        /// The directory is one item.
        case whole
        /// Each child is its own item (per project, per model, per skill), so
        /// the user can keep some. Children that are, or contain, another
        /// source's path are skipped so no byte is counted twice.
        case children
        /// Installed versions other than the one the tool uses, found by
        /// `SupersededVersions`. The current version is never an item, and a
        /// tool whose current version can't be read lists nothing.
        case superseded(SupersededVersions.Tool)
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
        .init(.devCaches, ".sbt/boot", "sbt launcher cache"),
        .init(.devCaches, ".coursier/cache", "Coursier cache"),
        .init(.devCaches, ".bun/install/cache", "Bun cache"),
        // Per child, so AI-agent entries that live in ~/.cache (codex runtimes,
        // Hugging Face) are skipped here and listed once under aiAgents.
        .init(.devCaches, ".cache", "XDG cache (~/.cache)", .safe, .children),
        .init(.devCaches, ".deno", "Deno cache"),
        .init(.devCaches, "Library/Developer/Xcode/iOS DeviceLogs", "iOS Device Logs"),
        .init(.devCaches, ".cocoapods", "CocoaPods cache"),
        .init(.devCaches, ".fastlane/caches", "Fastlane cache"),
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
        .init(.devCaches, "Library/Developer/Xcode/DocumentationCache", "Xcode documentation cache"),
        .init(.devCaches, "Library/Developer/XCTestDevices", "Simulators Xcode cloned for parallel tests"),
        .init(.devCaches, "Library/Developer/XCPGDevices", "Simulators Xcode made for playgrounds"),
        .init(.devCaches, "Library/iTunes/iPhone Software Updates", "iPhone update file (downloaded again if needed)", .safe, .children),
        .init(.devCaches, "Library/iTunes/iPad Software Updates", "iPad update file (downloaded again if needed)", .safe, .children),
        // On current toolchains this is a symlink to Library/Caches/org.swift.swiftpm,
        // listed above; only a real folder from an older toolchain is an item.
        .init(.devCaches, ".swiftpm/cache", "Swift Package Manager cache"),

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
        .init(.devCaches, ".pub-cache/hosted", "Dart and Flutter package cache"),
        .init(.devCaches, ".pub-cache/git", "Dart and Flutter git packages"),
        .init(.devCaches, "Library/Caches/Yarn", "Yarn cache"),
        .init(.devCaches, ".nvm/.cache", "nvm download cache"),
        .init(.devCaches, ".cache/node-gyp", "node-gyp headers"),
        .init(.devCaches, "Library/Caches/electron", "Electron downloads"),

        // Test browsers and IDEs
        .init(.devCaches, "Library/Caches/ms-playwright", "Playwright browser", .safe, .children),
        .init(.devCaches, ".cache/puppeteer", "Puppeteer browsers"),
        .init(.devCaches, "Library/Caches/Cypress", "Cypress binary", .safe, .children),
        .init(.devCaches, "Library/Caches/JetBrains", "JetBrains IDE cache (re-indexes on open)", .safe, .children),
        // The server itself downloads again on the next connection; extensions
        // don't, and each server's `data` folder (settings, state) is never listed.
        .init(.devCaches, ".vscode-server/bin", "VS Code remote server (downloaded again on connect)"),
        .init(.devCaches, ".vscode-server/cli/servers", "VS Code remote server (downloaded again on connect)"),
        .init(.devCaches, ".vscode-server/extensions", "VS Code remote extensions (reinstall needed)", .caution),
        .init(.devCaches, ".cursor-server/bin", "Cursor remote server (downloaded again on connect)"),
        .init(.devCaches, ".cursor-server/cli/servers", "Cursor remote server (downloaded again on connect)"),
        .init(.devCaches, ".cursor-server/extensions", "Cursor remote extensions (reinstall needed)", .caution),

        // Ruby, .NET, JVM, Haskell, OCaml, Elixir, Julia. Only the download
        // caches are Safe. Sibling folders hold config, tokens and things the
        // user published or installed, so these are never listed whole.
        .init(.devCaches, ".gem/specs", "RubyGems index cache"),
        .init(.devCaches, ".gem/ruby", "Gems installed for one Ruby (reinstall needed)", .caution, .children),
        .init(.devCaches, ".nuget/packages", "NuGet package cache"),
        .init(.devCaches, ".ivy2/cache", "Ivy cache"),
        .init(.devCaches, ".stack/pantry", "Stack package index"),
        .init(.devCaches, ".stack/programs", "GHC installed by Stack (downloaded again on build)", .caution),
        .init(.devCaches, ".stack/snapshots", "Haskell packages built by Stack (slow to rebuild)", .caution),
        .init(.devCaches, ".cabal/packages", "Cabal downloads (run cabal update afterwards)", .caution),
        .init(.devCaches, ".cabal/store", "Haskell packages built by Cabal (slow to rebuild)", .caution),
        .init(.devCaches, ".opam/download-cache", "opam download cache"),
        .init(.devCaches, ".hex/packages", "Hex package cache"),
        .init(.devCaches, ".mix/archives", "Mix archives (reinstall with mix local.hex)", .caution),
        .init(.devCaches, ".julia/artifacts", "Julia binary artifacts (run Pkg.instantiate afterwards)", .caution),
        .init(.devCaches, ".docker/buildx", "Docker Buildx state (custom builders are forgotten)", .caution),

        // ~/.local/share holds tools and people's own data side by side, so an
        // unknown child is Caution. What's named below is listed on its own,
        // and a child holding a named one is skipped: ~/.local/share/claude
        // (the Claude Code install) and ~/.local/share/uv never appear whole.
        .init(.devCaches, ".local/share", "Command-line tool data (may be your own, check first)", .caution, .children),
        .init(.devCaches, ".local/share/pnpm/store", "pnpm store"),
        .init(.devCaches, ".local/share/virtualenvs", "Pipenv virtualenv (pipenv install rebuilds it)", .caution, .children),
        .init(.devCaches, ".local/share/uv/python", "Python installed by uv (its tools and venvs stop working)", .caution, .children),
        .init(.devCaches, ".local/share/uv/tools", "Tool installed with uv (reinstall needed)", .caution, .children),
        .init(.devCaches, ".local/share/Trash", "Files command-line tools moved to their own trash", .caution),
        .init(.devCaches, ".local/share/containers", "Podman machines and images", .danger),

        // Superseded versions. Always Caution: none reinstalls itself, and a
        // project outside the dev roots may still ask for one.
        .init(.devCaches, ".nvm/versions/node", "Node version, not your nvm default (reinstall needed)", .caution, .superseded(.nvm)),
        .init(.devCaches, ".rbenv/versions", "Ruby version, not your rbenv global (reinstall needed)", .caution, .superseded(.rbenv)),
        .init(.devCaches, ".asdf/installs", "asdf version, not in ~/.tool-versions (reinstall needed)", .caution, .superseded(.asdf)),
        .init(.devCaches, "Library/Java/JavaVirtualMachines", "Older JDK build, a newer one is installed (reinstall needed)", .caution, .superseded(.java)),
        .init(.devCaches, "Library/Android/sdk/build-tools", "Older Android build tools (Gradle downloads them if needed)", .caution, .superseded(.androidBuildTools)),
        .init(.devCaches, "Library/Android/sdk/platforms", "Older Android platform (Gradle downloads it if needed)", .caution, .superseded(.androidPlatforms)),
        .init(.devCaches, "Library/Android/sdk/ndk", "Older Android NDK (Gradle downloads it if needed)", .caution, .superseded(.androidNDK)),
        .init(.devCaches, "Library/Application Support/JetBrains/Toolbox/apps", "Older IDE build Toolbox keeps for rollback", .caution, .superseded(.jetBrainsToolbox)),
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
        .init(.aiAgents, ".local/share/claude/versions", "Older Claude Code version, not the one in use", .caution, .superseded(.claudeCode)),
        // Hermes and Agent Reach keep tokens, memories and sessions beside
        // these, and Hermes runs from its checkout and environments, so only
        // download caches and tools that aren't in use are listed.
        .init(.aiAgents, ".hermes/cache/uv", "Hermes package cache"),
        .init(.aiAgents, ".hermes/tools", "Older Hermes tool, not the version in use", .caution, .superseded(.hermesTools)),
        .init(.aiAgents, ".agent-reach/cache", "Agent Reach download cache"),
        .init(.aiAgents, ".agent-reach/tools", "Agent Reach tool (reinstall needed)", .caution, .children),
        // Local models: big, slow to re-pull. Ollama is one store (blobs are
        // shared between models), so it is one item, never split.
        .init(.aiAgents, ".ollama/models", "Ollama models (re-pull needed)", .caution),
        .init(.aiAgents, ".cache/huggingface/hub", "Hugging Face model (re-download needed)", .caution, .children),
        .init(.aiAgents, ".lmstudio/models", "LM Studio models (re-download needed)", .caution, .children),
        .init(.aiAgents, ".lmstudio/extensions", "LM Studio runtimes (re-download needed)", .caution),
        .init(.aiAgents, ".lmstudio/hub", "LM Studio Hub downloads and presets", .caution),
    ]

    /// The source an item was found by. Matched on the path tail so it works
    /// for any home directory (tests use a fake one). Whole-dir sources match
    /// on path alone, so items restored from an older saved scan (e.g. Ollama
    /// models once listed under devCaches) still get today's risk tier.
    public static func source(for item: ScanItem) -> CleanSource? {
        let path = item.url.path
        let parent = item.url.deletingLastPathComponent().path
        // Most specific wins: Xcode/UserData/Previews (its own source) beats
        // the per-child Xcode/UserData source that also matches it. A plain
        // loop: this runs per item on every render that checks `risk`.
        var best: CleanSource?
        for source in all where source.path.count > (best?.path.count ?? -1) {
            let tail = "/" + source.path
            let matches = switch source.locate {
            case .whole: path.hasSuffix(tail)
            case .children: item.category == source.category && parent.hasSuffix(tail)
            // asdf and Toolbox nest versions a level or two below the source.
            case .superseded: item.category == source.category && path.contains(tail + "/")
            }
            if matches { best = source }
        }
        return best
    }
}

extension ScanItem {
    /// Risk of the registry source this item came from; items from bespoke
    /// scanners are judged at category level and report `.safe`.
    public var risk: Risk {
        // Application Support items carry their own knowledge; anything there
        // MacTidy doesn't recognise (a whole app folder from an older saved
        // scan) is app data, never safe by default.
        if category == .appSupport { return AppSupportRules.insight(for: self)?.risk ?? .caution }
        // Trashing a group container resets every app that shares it.
        if category == .groupContainers { return .caution }
        return CleanSource.source(for: self)?.risk ?? .safe
    }

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
        let policy = SafePathPolicy(home: home)
        let devRoots = devRoots
        let sources = CleanSource.all.filter { $0.category == category }
        let superseded = sources.filter { if case .superseded = $0.locate { true } else { false } }
        return await withTaskGroup(of: [ScanItem].self) { group in
            for source in sources where !superseded.contains(where: { $0.path == source.path }) {
                group.addTask { await Self.scan(source, home: home, allRoots: allRoots, policy: policy) }
            }
            group.addTask {
                Self.supersededItems(superseded, home: home, devRoots: devRoots, policy: policy)
            }
            var items: [ScanItem] = []
            for await batch in group { items += batch }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    private static func scan(_ source: CleanSource, home: URL, allRoots: [String],
                             policy: SafePathPolicy) async -> [ScanItem] {
        let url = home.appending(path: source.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        switch source.locate {
        case .whole:
            // A symlink's bytes belong to its target: sizing it would count
            // them twice, and trashing it would free nothing.
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return [] }
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
                    // Hidden loose files are bookkeeping (.DS_Store, .lock), and
                    // a child the policy refuses holds a secret: neither is a row.
                    let bookkeeping = !child.isDirectory && child.url.lastPathComponent.hasPrefix(".")
                    guard child.sizeBytes > 0, !bookkeeping,
                          case .success = policy.classify(child.url) else { return false }
                    return !allRoots.contains { $0 == p || $0.hasPrefix(p + "/") }
                }
                .map { ScanItem(url: $0.url, sizeBytes: $0.sizeBytes, isDirectory: $0.isDirectory,
                                category: source.category, detail: source.label.isEmpty ? nil : source.label,
                                lastModified: $0.lastModified) }
        case .superseded:
            return []  // Listed together by `supersededItems`.
        }
    }
}

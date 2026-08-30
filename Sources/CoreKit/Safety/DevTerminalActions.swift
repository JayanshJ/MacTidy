import Foundation

/// `ShellAction` conformances for the Developer Terminal module. Each mirrors
/// the Docker action pattern: stored model, computed display/command strings,
/// `reversible: false`, and a `run()` that does `Shell.find` → `Shell.run`.
/// These bypass the filesystem pipeline (`SafePathPolicy` / `Trasher`) by
/// design — they're tool-native cleanup commands, not path-based deletions.
/// The one exception is `CargoCacheCleanAction`, which trashes directories via
/// `Trasher` (Trash-undoable) but wraps the result in a `ShellAction` so it
/// appears in the same confirmation flow.

/// Kills a process by PID with SIGTERM (graceful). Never SIGKILL — let the
/// process clean up (close DB connections, flush writes). If it doesn't die,
/// the user can kill again. Guards against PID ≤ 1 and system denylisted names.
public struct KillProcessAction: ShellAction {
    public let id = UUID()
    public let pid: Int32
    public let name: String
    public let port: Int?
    public var displayName: String {
        var label = "Kill \(name) (PID \(pid)"
        if let port { label += ", port \(port)" }
        label += ")"
        return label
    }
    public var commandSummary: String { "kill -TERM \(pid)" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init(pid: Int32, name: String, port: Int? = nil) {
        self.pid = pid
        self.name = name
        self.port = port
    }

    public func run() -> Shell.Output? {
        guard pid > 1, !ProcessDenylist.isDenied(name) else { return nil }
        return Shell.run("/bin/kill", ["-TERM", "\(pid)"])
    }
}

/// Clears the npm download cache. `--force` is required because npm refuses to
/// clean a cache that's in use. Packages re-download on next install.
public struct NpmCacheCleanAction: ShellAction {
    public let id = UUID()
    public let estimatedBytes: Int64
    public var displayName: String { "npm cache" }
    public var commandSummary: String { "npm cache clean --force" }
    public var reversible: Bool { false }

    public init(estimatedBytes: Int64 = 0) { self.estimatedBytes = estimatedBytes }

    public func run() -> Shell.Output? {
        guard let npm = Shell.find("npm") else { return nil }
        return Shell.run(npm, ["cache", "clean", "--force"])
    }
}

/// Clears the Yarn package cache. Dependencies reinstall on demand.
public struct YarnCacheCleanAction: ShellAction {
    public let id = UUID()
    public let estimatedBytes: Int64
    public var displayName: String { "Yarn cache" }
    public var commandSummary: String { "yarn cache clean" }
    public var reversible: Bool { false }

    public init(estimatedBytes: Int64 = 0) { self.estimatedBytes = estimatedBytes }

    public func run() -> Shell.Output? {
        guard let yarn = Shell.find("yarn") else { return nil }
        return Shell.run(yarn, ["cache", "clean"])
    }
}

/// Prunes unreferenced packages from the pnpm global store. Safe — only
/// removes packages not linked to any project's node_modules.
public struct PnpmStorePruneAction: ShellAction {
    public let id = UUID()
    public let estimatedBytes: Int64
    public var displayName: String { "pnpm store" }
    public var commandSummary: String { "pnpm store prune" }
    public var reversible: Bool { false }

    public init(estimatedBytes: Int64 = 0) { self.estimatedBytes = estimatedBytes }

    public func run() -> Shell.Output? {
        guard let pnpm = Shell.find("pnpm") else { return nil }
        return Shell.run(pnpm, ["store", "prune"])
    }
}

/// Runs `brew cleanup --prune=0` — removes ALL stale downloads (any age) and
/// old formula versions. Brew re-downloads as needed. Distinct from trashing
/// the cache dir: brew cleanup also fixes symlinks and removes old version
/// bottles, letting Homebrew manage its own state.
public struct BrewCleanupAction: ShellAction {
    public let id = UUID()
    public let estimatedBytes: Int64
    public var displayName: String { "Homebrew (old versions + cache)" }
    public var commandSummary: String { "brew cleanup --prune=0" }
    public var reversible: Bool { false }

    public init(estimatedBytes: Int64 = 0) { self.estimatedBytes = estimatedBytes }

    public func run() -> Shell.Output? {
        guard let brew = Shell.find("brew") else { return nil }
        return Shell.run(brew, ["cleanup", "--prune=0"])
    }
}

/// Trashes the Cargo registry cache (`~/.cargo/registry/cache` and
/// `~/.cargo/registry/src`). Unlike the other actions, this routes through
/// `Trasher` (Trash-undoable) since cargo has no built-in cache-clean command
/// and these are plain directories. Crates re-download on next build.
public struct CargoCacheCleanAction: ShellAction {
    public let id = UUID()
    public let estimatedBytes: Int64
    public var displayName: String { "Cargo registry cache" }
    public var commandSummary: String { "trash ~/.cargo/registry/cache + ~/.cargo/registry/src" }
    public var reversible: Bool { false }

    public init(estimatedBytes: Int64 = 0) { self.estimatedBytes = estimatedBytes }

    public func run() -> Shell.Output? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            home.appending(path: ".cargo/registry/cache"),
            home.appending(path: ".cargo/registry/src"),
        ]
        var anyFailed = false
        var stderr = ""
        for dir in dirs where FileManager.default.fileExists(atPath: dir.path) {
            do {
                _ = try Trasher.trash(dir)
            } catch {
                anyFailed = true
                stderr += "\(dir.path): \(error.localizedDescription)\n"
            }
        }
        if anyFailed {
            return Shell.Output(stdout: "", stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines), exitCode: 1)
        }
        return Shell.Output(stdout: "", stderr: "", exitCode: 0)
    }
}

/// Prunes unused Docker volumes (`docker volume prune -f`). Only removes
/// volumes not referenced by any container — safe by Docker's own definition.
/// Irreversible (no Trash for Docker volumes).
public struct DockerVolumePruneAction: ShellAction {
    public let id = UUID()
    public let estimatedBytes: Int64
    public var displayName: String { "unused Docker volumes" }
    public var commandSummary: String { "docker volume prune -f" }
    public var reversible: Bool { false }

    public init(estimatedBytes: Int64 = 0) { self.estimatedBytes = estimatedBytes }

    public func run() -> Shell.Output? {
        guard let docker = Shell.find("docker") else { return nil }
        return Shell.run(docker, ["volume", "prune", "-f"])
    }
}

/// Deletes iOS Simulator runtimes for Xcode versions no longer installed
/// (`xcrun simctl delete unavailable`). Frees the large runtime images in
/// ~/Library/Developer/CoreSimulator/Images. `estimatedBytes` is 0 because
/// simctl doesn't report per-runtime sizes — the log stays honest.
public struct SimctlDeleteUnavailableAction: ShellAction {
    public let id = UUID()
    public let unavailableCount: Int
    public var displayName: String { "unavailable iOS Simulators (\(unavailableCount))" }
    public var commandSummary: String { "xcrun simctl delete unavailable" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init(unavailableCount: Int = 0) { self.unavailableCount = unavailableCount }

    public func run() -> Shell.Output? {
        guard let xcrun = Shell.find("xcrun") else { return nil }
        return Shell.run(xcrun, ["simctl", "delete", "unavailable"])
    }
}
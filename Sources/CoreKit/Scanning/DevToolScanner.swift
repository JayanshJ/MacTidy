import Foundation

/// A developer tool whose cache can be cleaned. Each tool has a scanner that
/// measures the current cache size, and a `ShellAction` that cleans it (in
/// `DevTerminalActions.swift`). The scanner is read-only; the action is the
/// destructive step.
public struct DevToolInfo: Identifiable, Sendable {
    public let id = UUID()
    public let tool: DevTool
    /// Current cache size in bytes, or 0 if unmeasurable.
    public let cacheBytes: Int64
    /// Tool version string (e.g. "10.8.2"), nil if the tool doesn't report one.
    public let version: String?
    /// The resolved path to the tool's binary, or nil if not found.
    public let path: String?
    /// For simctl: the count of unavailable simulators. 0 for other tools.
    public let simctlUnavailableCount: Int

    public init(tool: DevTool, cacheBytes: Int64, version: String?, path: String?, simctlUnavailableCount: Int = 0) {
        self.tool = tool
        self.cacheBytes = cacheBytes
        self.version = version
        self.path = path
        self.simctlUnavailableCount = simctlUnavailableCount
    }
}

/// The developer tools the Developer Terminal module knows how to clean.
/// Each case maps to a `ShellAction` conformance in `DevTerminalActions.swift`.
public enum DevTool: String, Sendable, CaseIterable {
    case npm
    case yarn
    case pnpm
    case brew
    case cargo
    case simctl

    public var displayName: String {
        switch self {
        case .npm: "npm cache"
        case .yarn: "Yarn cache"
        case .pnpm: "pnpm store"
        case .brew: "Homebrew"
        case .cargo: "Cargo registry"
        case .simctl: "iOS Simulators"
        }
    }

    public var icon: String {
        switch self {
        case .npm: "shippingbox"
        case .yarn: "shippingbox"
        case .pnpm: "shippingbox"
        case .brew: "mug.and.saucer.fill"
        case .cargo: "cylinder.split.1x2"
        case .simctl: "iphone"
        }
    }

    /// One-line description of what cleaning this tool does.
    public var cleanDescription: String {
        switch self {
        case .npm: "Clears the npm download cache. Packages reinstall on demand."
        case .yarn: "Clears the Yarn package cache. Dependencies reinstall on demand."
        case .pnpm: "Prunes unreferenced packages from the pnpm global store."
        case .brew: "Removes stale downloads and old formula versions. Brew re-downloads as needed."
        case .cargo: "Trashes the Cargo registry cache. Crates re-download on next build."
        case .simctl: "Deletes simulator runtimes for Xcode versions no longer installed."
        }
    }
}

/// Read-only scanner that measures the cache footprint of each installed
/// developer tool. Mirrors `DockerBuilderCache`'s pattern: best-effort sizes,
/// nil/0 on missing tools, never throws. Parallel via `withTaskGroup`.
public enum DevToolScanner {
    /// Scans all known dev tools and returns info for those that are installed
    /// and have a non-zero cache (or, for simctl, unavailable runtimes).
    public static func scan() async -> [DevToolInfo] {
        await withTaskGroup(of: DevToolInfo?.self) { group in
            for tool in DevTool.allCases {
                group.addTask { await scanTool(tool) }
            }
            var results: [DevToolInfo] = []
            for await info in group where info != nil {
                if info!.cacheBytes > 0 || info!.simctlUnavailableCount > 0 {
                    results.append(info!)
                }
            }
            return results.sorted { $0.cacheBytes > $1.cacheBytes }
        }
    }

    /// Scans a single tool. Returns nil if the tool isn't installed.
    static func scanTool(_ tool: DevTool) async -> DevToolInfo? {
        switch tool {
        case .npm: return scanNpm()
        case .yarn: return scanYarn()
        case .pnpm: return scanPnpm()
        case .brew: return scanBrew()
        case .cargo: return scanCargo()
        case .simctl: return scanSimctl()
        }
    }

    // MARK: - Per-tool scanners

    private static func scanNpm() -> DevToolInfo? {
        guard let npm = Shell.find("npm") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bytes = duBytes(home.appending(path: ".npm"))
        return DevToolInfo(tool: .npm, cacheBytes: bytes ?? 0, version: version(of: npm), path: npm)
    }

    private static func scanYarn() -> DevToolInfo? {
        guard let yarn = Shell.find("yarn") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Yarn Classic cache is at ~/.yarn/cache; Yarn Berry uses per-project .yarn/cache.
        let bytes = duBytes(home.appending(path: ".yarn/cache"))
            ?? duBytes(home.appending(path: ".yarn"))
        return DevToolInfo(tool: .yarn, cacheBytes: bytes ?? 0, version: version(of: yarn), path: yarn)
    }

    private static func scanPnpm() -> DevToolInfo? {
        guard let pnpm = Shell.find("pnpm") else { return nil }
        // `pnpm store path` prints the global store path; measure it with du.
        guard let output = Shell.run(pnpm, ["store", "path"]), output.succeeded else {
            return DevToolInfo(tool: .pnpm, cacheBytes: 0, version: version(of: pnpm), path: pnpm)
        }
        let storePath = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = duBytes(URL(fileURLWithPath: storePath))
        return DevToolInfo(tool: .pnpm, cacheBytes: bytes ?? 0, version: version(of: pnpm), path: pnpm)
    }

    private static func scanBrew() -> DevToolInfo? {
        guard let brew = Shell.find("brew") else { return nil }
        guard let output = Shell.run(brew, ["--cache"]), output.succeeded else {
            return DevToolInfo(tool: .brew, cacheBytes: 0, version: version(of: brew), path: brew)
        }
        let cachePath = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = duBytes(URL(fileURLWithPath: cachePath))
        return DevToolInfo(tool: .brew, cacheBytes: bytes ?? 0, version: version(of: brew), path: brew)
    }

    private static func scanCargo() -> DevToolInfo? {
        guard let cargo = Shell.find("cargo") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bytes = duBytes(home.appending(path: ".cargo/registry"))
            ?? duBytes(home.appending(path: ".cargo"))
        return DevToolInfo(tool: .cargo, cacheBytes: bytes ?? 0, version: version(of: cargo), path: cargo)
    }

    private static func scanSimctl() -> DevToolInfo? {
        guard let xcrun = Shell.find("xcrun") else { return nil }
        // `xcrun simctl list devices unavailable` lists runtimes for Xcode
        // versions no longer installed. Each unavailable device line contains
        // a parenthesized runtime identifier. Count them.
        guard let output = Shell.run(xcrun, ["simctl", "list", "devices", "unavailable"]),
              output.succeeded else {
            return DevToolInfo(tool: .simctl, cacheBytes: 0, version: nil, path: xcrun)
        }
        let count = parseSimctlUnavailable(output.stdout)
        // The runtime images live in ~/Library/Developer/CoreSimulator/Images;
        // measure that dir for a size estimate. It may include available
        // runtimes too, so we show it as an upper bound.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let imagesBytes = duBytes(home.appending(path: "Library/Developer/CoreSimulator/Images")) ?? 0
        return DevToolInfo(tool: .simctl, cacheBytes: imagesBytes, version: nil,
                           path: xcrun, simctlUnavailableCount: count)
    }

    // MARK: - Shared helpers

    /// Runs `du -sk <url>` and returns bytes (KB × 1024). Returns nil if the
    /// directory doesn't exist or du fails.
    static func duBytes(_ url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let output = Shell.run("/usr/bin/du", ["-sk", url.path]),
              output.succeeded else { return nil }
        return parseDuBytes(output.stdout)
    }

    /// Parses the first number from `du -sk` output (e.g. `"482304\t/path"`)
    /// and converts KB to bytes. Pure — unit-tested.
    public static func parseDuBytes(_ stdout: String) -> Int64? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tabIdx = trimmed.firstIndex(of: "\t") else { return nil }
        let kbStr = String(trimmed[trimmed.startIndex..<tabIdx])
        guard let kb = Int64(kbStr) else { return nil }
        return kb * 1024
    }

    /// Counts unavailable simulators from `simctl list devices unavailable`
    /// output. Each device line ends with a parenthesized runtime identifier;
    // count lines that look like device entries (not section headers).
    public static func parseSimctlUnavailable(_ stdout: String) -> Int {
        stdout.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.contains("(") && !$0.hasSuffix(":") }
            .count
    }

    /// Runs `tool --version` and returns the first non-empty line, trimmed.
    private static func version(of toolPath: String) -> String? {
        guard let output = Shell.run(toolPath, ["--version"]), output.succeeded else { return nil }
        let firstLine = output.stdout.split(separator: "\n").first.map(String.init)
        return firstLine?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
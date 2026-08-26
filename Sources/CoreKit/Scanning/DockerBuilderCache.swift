import Foundation

/// Docker BuildKit cache: layer and build cache that accumulates from
/// `docker build`. Distinct from images/containers (which the Docker tab
/// already handles) and from `docker system prune` (which MacTidy never
/// runs). `docker builder prune -f` clears only the BuildKit cache, which
/// rebuilds on demand.
///
/// Not Trash-undoable, so this flows through the `ShellAction` path
/// (parallel to the filesystem `Trasher` path), exactly like the existing
/// Docker compose-down / image-remove actions. Manual-only in the UI.

/// Reads the BuildKit cache size from `docker builder df` (best-effort).
/// `docker builder df` prints a `TYPE  TOTAL  ACTIVE  SIZE  RECLAIMABLE`
/// table; the `Build Cache` row's `SIZE` is what we report. Returns nil
/// when Docker is unavailable or the value can't be parsed.
public enum DockerBuilderCache {
    /// Best-effort reclaimable bytes from `docker builder df`. Returns nil
    /// when Docker isn't available or the size can't be parsed.
    public static func reclaimableBytes() -> Int64? {
        guard let docker = Shell.find("docker") else { return nil }
        guard let output = Shell.run(docker, ["builder", "df"]),
              output.succeeded else { return nil }
        return parseReclaimableBytes(output.stdout)
    }

    /// Parses `docker builder df` stdout for the `Build Cache` reclaimable
    /// size. Lines are whitespace-separated:
    ///   `Build Cache   123   45   1.2GB   800MB`
    /// The last column (RECLAIMABLE) is what we report. Human sizes like
    /// `1.2GB` are parsed into bytes; unparseable → nil.
    public static func parseReclaimableBytes(_ stdout: String) -> Int64? {
        for rawLine in stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Build Cache") else { continue }
            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // Expect: ["Build", "Cache", TOTAL, ACTIVE, SIZE, RECLAIMABLE]
            guard cols.count >= 6 else { return nil }
            return parseHumanBytes(cols[5]) ?? parseHumanBytes(cols[4])
        }
        return nil
    }

    /// Parses a human byte string like `1.2GB`, `800MB`, `512B` into bytes.
    /// Returns nil for anything unparseable.
    private static func parseHumanBytes(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let digitEnd = trimmed.lastIndex(where: { $0.isNumber || $0 == "." }) else {
            return nil
        }
        let numPart = String(trimmed[...digitEnd])
        let unit = String(trimmed[trimmed.index(after: digitEnd)...]).uppercased()
        guard let value = Double(numPart) else { return nil }
        let multiplier: Double
        switch unit {
        case "", "B": multiplier = 1
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        case "TB": multiplier = 1_000_000_000_000
        default: return nil
        }
        return Int64(value * multiplier)
    }
}

/// Runs `docker builder prune -f` to clear the BuildKit cache. Not reversible.
public struct DockerBuilderPruneAction: ShellAction {
    public let id = UUID()
    public let estimatedBytes: Int64

    /// `estimatedBytes` is best-effort from `DockerBuilderCache.reclaimableBytes()`;
    /// pass 0 when unknown — the confirmation sheet shows the literal command
    /// and the honest "size unknown" note either way.
    public init(estimatedBytes: Int64 = 0) { self.estimatedBytes = estimatedBytes }

    public var displayName: String { "Docker builder cache (BuildKit)" }
    public var commandSummary: String { "docker builder prune -f" }
    public var reversible: Bool { false }

    public func run() -> Shell.Output? {
        guard let docker = Shell.find("docker") else { return nil }
        return Shell.run(docker, ["builder", "prune", "-f"])
    }
}
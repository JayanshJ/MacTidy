import Foundation

/// macOS kernel memory-pressure level, read live from
/// `sysctl kern.memorystatus_vm_pressure_level`. This — not "bytes free" — is
/// the number that predicts trouble: macOS keeps RAM deliberately full with
/// cache and only these levels rising means apps are about to feel it or be
/// jetsammed. Levels mirror Activity Monitor's Normal / Warning / Critical.
public enum MemoryPressureLevel: Int, Sendable, Codable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    /// Maps a raw `kern.memorystatus_vm_pressure_level` value. The kernel only
    /// emits 1, 2, and 4; anything else is clamped to the nearest level rather
    /// than failing, so a future value can't break the UI.
    public static func parse(rawValue: Int32) -> MemoryPressureLevel {
        switch rawValue {
        case ...1: .normal
        case 2, 3: .warning
        default: .critical
        }
    }
}

/// Read-only memory-pressure probe. Degrades gracefully: an unavailable
/// sysctl yields nil, never a wrong answer.
public enum MemoryPressure {
    /// Current kernel pressure level, or nil when it can't be read.
    public static func currentLevel() -> MemoryPressureLevel? {
        guard let out = Shell.run("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"]) else {
            return nil
        }
        guard let raw = Int32(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return .parse(rawValue: raw)
    }
}

/// The one deliberate memory action MacTidy offers beyond quitting idle apps:
/// purging the disk cache via `/usr/sbin/purge`. Honest contract: this drops
/// file caches so inactive memory shows as free, but caches rebuild — the
/// effect is temporary and can make subsequent launches slower. It's gated
/// behind an admin prompt (purge needs root) and never run automatically.
public enum MemoryMaintenance {
    public enum PurgeResult: Equatable, Sendable {
        case purged
        case adminPromptCancelled
        case failed(String)
    }

    /// Runs `purge` via the standard macOS admin-auth dialog. Non-throwing.
    public static func purgeDiskCache() -> PurgeResult {
        // Single quoted command through do shell script; purge takes no args.
        let script = "/usr/sbin/purge"
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        guard let out = Shell.run("/usr/bin/osascript", ["-e", appleScript]) else {
            return .failed("osascript unavailable")
        }
        if out.succeeded { return .purged }
        if out.stderr.contains("User canceled") || out.stderr.contains("-128") {
            return .adminPromptCancelled
        }
        return .failed(Shell.humanReadableAppleScriptError(out.stderr.isEmpty ? out.stdout : out.stderr))
    }
}

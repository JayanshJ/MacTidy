import Foundation
import Darwin

/// Explicit manual exception to move-to-Trash cleanup: Finder owns permanent
/// disposal. Never called by scanning, scheduling, or a DeletionPlan.
public enum TrashEmptying {
    public enum Result: Sendable, Equatable {
        case completed
        case cancelled
        case failed(String)
    }

    public static func emptyUsingFinder() -> Result {
        guard let output = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"]) else {
            return .failed("Finder could not be contacted.")
        }
        return interpret(succeeded: output.succeeded, error: output.stderr)
    }

    public static func interpret(succeeded: Bool, error: String) -> Result {
        if succeeded { return .completed }
        if error.contains("-128") || error.contains("User canceled") { return .cancelled }
        return .failed(Shell.humanReadableAppleScriptError(error))
    }

    /// Immediate free blocks, excluding purgeable-space estimates.
    public static func freeBytes() -> Int64? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }
}

public struct TrashSpaceMeasurement: Codable, Sendable {
    public let date: Date
    public let before: Int64?
    public let after: Int64?
    public var change: Int64? {
        guard let before, let after else { return nil }
        return after - before
    }
    public init(date: Date = Date(), before: Int64?, after: Int64?) {
        self.date = date; self.before = before; self.after = after
    }
}

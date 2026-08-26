import Foundation

/// Time Machine local snapshots live on the startup volume and can tie up
/// tens of GB. macOS creates and expires them on its own schedule; deleting
/// one manually is safe — the next backup / Time Machine reclaims the space
/// and recreates snapshots as needed. Unlike trashed files, deletion is **not
/// Trash-undoable**, so this flows through the `ShellAction` path (the same
/// path Docker uses), not `Trasher`.
///
/// Read-only scanning lives here; the destructive `DeleteSnapshotAction`
/// shells out to `tmutil deletelocalsnapshots`. Both are manual-only in the
/// UI — never scheduled, never preselected, never bulk-run without a
/// confirmation sheet that shows the literal command.

/// One local Time Machine snapshot, as reported by `tmutil listlocalsnapshots`.
/// `name` is the full token (`com.apple.TimeMachine.2026-08-26-002000`); `date`
/// is the trailing timestamp portion (`2026-08-26-002000`), which is what
/// `tmutil deletelocalsnapshots` expects.
public struct TMSnapshot: Identifiable, Sendable, Hashable {
    public let name: String
    public let date: String
    public var id: String { name }

    public init(name: String, date: String) {
        self.name = name
        self.date = date
    }
}

/// Parses `tmutil listlocalsnapshots /` into `[TMSnapshot]`. Read-only.
public enum TimeMachineScanner {
    /// `/usr/bin/tmutil` is always present on macOS. Returns an empty list
    /// when tmutil is missing or there are no snapshots.
    public static func listSnapshots() -> [TMSnapshot] {
        guard let output = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]),
              output.succeeded else { return [] }
        return parse(output.stdout)
    }

    /// Parses the stdout of `tmutil listlocalsnapshots /`. Lines look like:
    ///   `Snapshot Date: 2026-08-26-002000`  (newer tmutil)
    ///   `com.apple.TimeMachine.2026-08-26-002000`  (older tmutil)
    /// Both forms are handled: we extract the trailing `YYYY-MM-DD-HHMMSS`
    /// token and synthesize the full `com.apple.TimeMachine.<token>` name.
    public static func parse(_ stdout: String) -> [TMSnapshot] {
        var snapshots: [TMSnapshot] = []
        for rawLine in stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Form 1: "Snapshot Date: 2026-08-26-002000"
            if let range = line.range(of: "Snapshot Date:") {
                let token = line[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                if !token.isEmpty {
                    snapshots.append(TMSnapshot(
                        name: "com.apple.TimeMachine.\(token)", date: token))
                }
                continue
            }
            // Form 2: "com.apple.TimeMachine.2026-08-26-002000"
            if line.hasPrefix("com.apple.TimeMachine.") {
                let token = String(line.dropFirst("com.apple.TimeMachine.".count))
                if !token.isEmpty {
                    snapshots.append(TMSnapshot(name: line, date: token))
                }
            }
        }
        return snapshots
    }

    /// Whether the startup volume has any local snapshots. Cheap predicate
    /// for gating the UI's "you have N snapshots" card.
    public static func hasSnapshots() -> Bool { !listSnapshots().isEmpty }
}

/// Deletes one local Time Machine snapshot via
/// `tmutil deletelocalsnapshots <date>`. Not reversible.
public struct DeleteSnapshotAction: ShellAction {
    public let id = UUID()
    public let snapshot: TMSnapshot

    public init(snapshot: TMSnapshot) { self.snapshot = snapshot }

    public var displayName: String { "Time Machine snapshot \(snapshot.date)" }
    public var commandSummary: String {
        "tmutil deletelocalsnapshots \(snapshot.date)"
    }
    /// `tmutil` doesn't report per-snapshot size, so we can't estimate the
    /// reclaim honestly. Zero keeps the reclaim-over-time log honest (we
    /// don't know how much this freed) — the UI explains this.
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public func run() -> Shell.Output? {
        Shell.run("/usr/bin/tmutil", ["deletelocalsnapshots", snapshot.date])
    }
}
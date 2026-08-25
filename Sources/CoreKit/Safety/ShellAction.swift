import Foundation

/// A destructive action executed by shelling out to an external tool (docker,
/// brew, …) rather than mutating the filesystem via `Trasher`. Unlike trashed
/// files, shell actions are generally **not** Trash-undoable — the confirmation
/// sheet makes that explicit. This path is parallel to, and deliberately
/// separate from, the filesystem pipeline (`SafePathPolicy` + `Trasher`).
public protocol ShellAction: Identifiable, Sendable {
    var id: UUID { get }
    /// Human label for the confirmation sheet, e.g. "Image postgres:15".
    var displayName: String { get }
    /// The literal command that will run, shown verbatim in the confirmation
    /// sheet so the user sees exactly what MacTidy will execute.
    var commandSummary: String { get }
    /// `false` for actions with no Trash-based undo (all Docker actions).
    var reversible: Bool { get }
    /// Estimated bytes this action reclaims, for the confirmation total and
    /// the reclaim-over-time log. An estimate — shared layers over-count.
    var estimatedBytes: Int64 { get }
    /// Runs the real command. Returns nil only if the process could not be
    /// launched; a non-nil Output with a non-zero exitCode is a per-item failure.
    func run() -> Shell.Output?
}

/// Outcome of executing a batch of `ShellAction`s. Per-item fail-closed: a
/// failed action is reported in `failed` and does not abort the rest.
public struct ShellActionOutcome: Sendable {
    public struct Failure: Identifiable, Sendable {
        public let id: UUID
        public let action: any ShellAction
        public let message: String
        public init(action: any ShellAction, message: String) {
            self.id = UUID()
            self.action = action
            self.message = message
        }
    }
    public var succeeded: [any ShellAction]
    public var failed: [Failure]
    public var dryRun: Bool

    public init(succeeded: [any ShellAction] = [], failed: [Failure] = [], dryRun: Bool) {
        self.succeeded = succeeded
        self.failed = failed
        self.dryRun = dryRun
    }

    public var reclaimedBytes: Int64 {
        succeeded.reduce(0) { $0 + $1.estimatedBytes }
    }
}

public enum ShellActionExecutor {
    /// Executes `actions` per-item. In `dryRun`, nothing runs — every action is
    /// reported as would-run (`succeeded`, with the dry-run flag set so the UI
    /// can show "would have run"). Otherwise each action runs; success adds to
    /// `succeeded`, failure (nil Output or non-zero exit) adds to `failed`
    /// with the real stderr. A failure never aborts the remaining actions.
    public static func execute(_ actions: [any ShellAction], dryRun: Bool) -> ShellActionOutcome {
        if dryRun {
            return ShellActionOutcome(succeeded: actions, failed: [], dryRun: true)
        }
        var succeeded: [any ShellAction] = []
        var failed: [ShellActionOutcome.Failure] = []
        for action in actions {
            guard let output = action.run() else {
                failed.append(.init(action: action, message: "Failed to launch command."))
                continue
            }
            if output.succeeded {
                succeeded.append(action)
            } else {
                let msg = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                failed.append(.init(action: action, message: msg.isEmpty ? "Command exited with code \(output.exitCode)." : msg))
            }
        }
        return ShellActionOutcome(succeeded: succeeded, failed: failed, dryRun: false)
    }
}
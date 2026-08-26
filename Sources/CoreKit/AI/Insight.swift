import Foundation

/// A point-in-time snapshot of everything MacTidy can reason over: disk
/// reclaim opportunities, system memory, running processes, boot-volume
/// pressure, and login items. This is the payload the AI advisor is asked to
/// turn into narrative insights. The sanitizer applies before it ever leaves
/// the machine.
public struct SystemSnapshot: Sendable {
    public let categories: [CategoryResult]
    public let memory: ProcessScanner.MemorySummary?
    public let processes: [RunningProcess]
    /// Free/total space on the boot volume — drives the "disk is almost full"
    /// insight. nil when the capacities couldn't be read.
    public let diskPressure: DiskPressure?
    /// Login items the user can act on — drives "this slows startup" insights.
    /// nil when the auditor wasn't run (kept optional so callers that don't
    /// care don't pay for the audit).
    public let launchItems: [LaunchItem]?

    public init(categories: [CategoryResult],
                memory: ProcessScanner.MemorySummary?,
                processes: [RunningProcess],
                diskPressure: DiskPressure? = nil,
                launchItems: [LaunchItem]? = nil) {
        self.categories = categories
        self.memory = memory
        self.processes = processes
        self.diskPressure = diskPressure
        self.launchItems = launchItems
    }
}

/// One proactive insight the AI surfaces: a narrative sentence plus a
/// proposed action. The action is *always* a suggestion — it routes through
/// the existing confirmation flow (SafePathPolicy for trashing, a quit
/// confirmation for processes). The model never executes.
public struct Insight: Identifiable, Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        /// Trash a set of disk items (caches, build artifacts, etc.).
        case trash(items: [ScanItem])
        /// Quit one or more running apps by name. Only user apps the policy
        /// allows; the denylist is checked before any quit happens.
        case quitApps(names: [String])
        /// Information only — no action proposed (e.g. "Docker is using a lot
        /// of disk but you may need it").
        case observe
    }

    public enum Kind: String, Sendable {
        case disk = "Disk"
        case memory = "Memory"
        case processes = "Processes"
        case combo = "Across resources"

        public var icon: String {
            switch self {
            case .disk: "internaldrive"
            case .memory: "memorychip"
            case .processes: "gearshape.2"
            case .combo: "sparkles"
            }
        }
    }

    public let id = UUID()
    public let kind: Kind
    /// One narrative sentence the user reads — the "why", not the "what".
    public let reasoning: String
    /// The proposed action, or .observe when there's nothing safe to do.
    public let action: Action
    /// Bytes this would reclaim (RAM for quits, disk for trash); 0 for observe.
    public let reclaimableBytes: Int64
    /// Low/medium/high value, used to sort insights.
    public let priority: Int

    public init(kind: Kind, reasoning: String, action: Action,
                reclaimableBytes: Int64, priority: Int) {
        self.kind = kind
        self.reasoning = reasoning
        self.action = action
        self.reclaimableBytes = reclaimableBytes
        self.priority = priority
    }
}
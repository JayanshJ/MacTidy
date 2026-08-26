import Foundation

/// Read-only snapshot of free space on the boot volume, used to surface
/// "disk is almost full" insights. Display + reasoning only — never modifies
/// anything. macOS reports two relevant capacities; we use the "important
/// usage" one (the space available to apps the user cares about) when present,
/// falling back to the generic available capacity.
public struct DiskPressure: Sendable {
    public let totalBytes: Int64
    public let freeBytes: Int64
    /// 0–1 fraction of the volume that is used. 0 when total is unknown.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return 1 - Double(freeBytes) / Double(totalBytes)
    }
    public var isAvailable: Bool { totalBytes > 0 }

    public init(totalBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    /// Probe the boot volume (`/`). Returns nil if the capacities can't be
    /// read (very unusual; degrades to "no disk-pressure insight").
    public static func current() -> DiskPressure? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        // Prefer "important usage" capacity — what's available to foreground
        // apps — then fall back to the generic available capacity. Both
        // properties are optional Int; unwrap via map then coerce to Int64.
        let important = values.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
        let generic = values.volumeAvailableCapacity.map { Int64($0) }
        let free = important ?? generic ?? 0
        guard total > 0 else { return nil }
        return DiskPressure(totalBytes: total, freeBytes: free)
    }
}
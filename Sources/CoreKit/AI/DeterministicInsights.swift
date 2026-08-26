import Foundation

/// Locally-generated insights, no AI required. The Insights panel uses these
/// when no provider is configured or the advisor call fails, so the feature is
/// useful out of the box. Honest and conservative: only surfaces what the
/// deterministic scanners can justify, never proposes quitting system
/// processes, and always routes proposed deletions through the policy.
public enum DeterministicInsights {
    public static func from(_ snapshot: SystemSnapshot) -> [Insight] {
        var insights: [Insight] = []

        // 1. Biggest safe disk category — the headline reclaim.
        let safe = snapshot.categories.filter { $0.category.isPreselectable && !$0.items.isEmpty }
        if let biggest = safe.max(by: { $0.totalBytes < $1.totalBytes }), biggest.totalBytes > 100 * 1024 * 1024 {
            insights.append(Insight(
                kind: .disk,
                reasoning: "\(biggest.category.displayName) is holding \(biggest.totalBytes.formattedBytes) — safe to clear, it rebuilds on demand.",
                action: .trash(items: biggest.items),
                reclaimableBytes: biggest.totalBytes,
                priority: Int(biggest.totalBytes / 1024 / 1024)
            ))
        }

        // 2. Idle user apps burning RAM — the "free up memory" insight.
        // Only user apps (have a bundle path) above 200MB, near-zero CPU.
        let idleHogs = snapshot.processes.filter {
            $0.appBundlePath != nil
                && !ProcessDenylist.isDenied($0.name)
                && $0.cpuPercent < 1.0
                && $0.residentBytes > 200 * 1024 * 1024
        }
        // Roll up by app name so "Chrome Helper (Renderer)" ×6 counts once.
        let byName = Dictionary(grouping: idleHogs, by: \.name)
        let ranked = byName.map { (name, procs) -> (String, Int64, Int) in
            (name, procs.reduce(0) { $0 + $1.residentBytes }, procs.count)
        }.sorted { $0.1 > $1.1 }
        if let top = ranked.first(where: { $0.1 > 300 * 1024 * 1024 }) {
            insights.append(Insight(
                kind: .memory,
                reasoning: "\(top.0) is holding \(top.1.formattedBytes) across \(top.2) \(top.2 == 1 ? "process" : "processes") and is idle (near 0% CPU) — quitting frees that RAM.",
                action: .quitApps(names: [top.0]),
                reclaimableBytes: top.1,
                priority: Int(top.1 / 1024 / 1024)
            ))
        }

        // 3. Memory pressure observation — honest, no action when the OS is fine.
        if let mem = snapshot.memory {
            let usedPct = mem.totalBytes > 0 ? Double(mem.usedBytes) / Double(mem.totalBytes) : 0
            if usedPct > 0.85 {
                insights.append(Insight(
                    kind: .memory,
                    reasoning: "Memory is \(Int(usedPct * 100))% full with \(mem.swapUsedBytes.formattedBytes) of swap in use — quitting idle apps would help more than usual.",
                    action: .observe,
                    reclaimableBytes: 0,
                    priority: 5
                ))
            } else if mem.swapUsedBytes > 2 * 1_073_741_824 {
                insights.append(Insight(
                    kind: .memory,
                    reasoning: "\(mem.swapUsedBytes.formattedBytes) of swap is in use — the OS is paging to disk. Quitting heavy idle apps reduces this.",
                    action: .observe,
                    reclaimableBytes: 0,
                    priority: 4
                ))
            }
        }

        // 4. Suggest-only category nudge — only when it's large and stale.
        if let bigFiles = snapshot.categories.first(where: { $0.category == .bigFiles }),
           bigFiles.totalBytes > 5 * 1_073_741_824 {
            insights.append(Insight(
                kind: .disk,
                reasoning: "\(bigFiles.totalBytes.formattedBytes) of large files found — review them; some may be junk, others (videos, VMs) you need. Marked review, not auto-trashed.",
                action: .observe,
                reclaimableBytes: 0,
                priority: 2
            ))
        }

        // 5. Disk almost full — surface the biggest safe reclaim framed as
        // urgent when free space is under 10%. Reuses the existing trash
        // action; no new destructive path.
        if let pressure = snapshot.diskPressure, pressure.isAvailable,
           let biggest = safe.max(by: { $0.totalBytes < $1.totalBytes }),
           biggest.totalBytes > 100 * 1024 * 1024,
           pressure.freeBytes < pressure.totalBytes / 10 {
            let usedPct = Int(pressure.usedFraction * 100)
            insights.append(Insight(
                kind: .disk,
                reasoning: "Your disk is \(usedPct)% full — only \(pressure.freeBytes.formattedBytes) free. Clearing \(biggest.category.displayName) (\(biggest.totalBytes.formattedBytes)) is the fastest way back.",
                action: .trash(items: biggest.items),
                reclaimableBytes: biggest.totalBytes,
                priority: Int(biggest.totalBytes / 1024 / 1024) + 50
            ))
        }

        // 6. Heavy startup — observe-only. MacTidy points at a long list of
        // login items; the user disables them in System Settings. Never wires
        // a destructive path for launch items.
        if let items = snapshot.launchItems, items.count >= 12 {
            insights.append(Insight(
                kind: .processes,
                reasoning: "\(items.count) login items run at startup. Each adds to boot time and background RAM. Review the ones you don't need in the Startup tab or System Settings → General → Login Items.",
                action: .observe,
                reclaimableBytes: 0,
                priority: 3
            ))
        }

        return insights.sorted { $0.priority > $1.priority }
    }
}
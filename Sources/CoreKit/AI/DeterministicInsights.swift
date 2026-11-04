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
        // Per-item gate: Caution/Danger registry items (VM disks, models) never
        // ride along in a "safe to clear" action.
        let safe = snapshot.categories
            .filter { $0.category.isPreselectable }
            .map { CategoryResult(category: $0.category, items: $0.items.filter { $0.risk == .safe }) }
            .filter { !$0.items.isEmpty }
        if let biggest = safe.max(by: { $0.totalBytes < $1.totalBytes }), biggest.totalBytes > 100 * 1024 * 1024 {
            insights.append(Insight(
                kind: .disk,
                reasoning: "\(biggest.category.displayName) is holding \(biggest.totalBytes.formattedBytes) — safe to clear, it rebuilds on demand.",
                action: .trash(items: biggest.items),
                reclaimableBytes: biggest.totalBytes,
                priority: Int(biggest.totalBytes / 1024 / 1024)
            ))
        }

        let candidates = MemoryAdvice.candidates(processes: snapshot.processes,
            pressure: snapshot.memoryPressure, swapBytes: snapshot.memory?.swapUsedBytes ?? 0)
        if let app = candidates.first, let bytes = app.footprintBytes {
            insights.append(Insight(kind: .memory,
                reasoning: "\(app.name) has been in the background for at least five minutes and uses about \(bytes.formattedBytes). Quitting may help while memory pressure or swap is elevated.",
                action: .quitApps(names: [app.name]), reclaimableBytes: bytes,
                priority: Int(bytes / 1024 / 1024)))
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
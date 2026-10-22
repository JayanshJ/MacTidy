import SwiftUI
import CoreKit

/// Timeline of completed cleanups: grouped by calendar week, newest first.
/// Shows what was cleaned, when, how many items, and how much space was freed.
struct CleanupHistoryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Page("Cleanup Log",
             subtitle: state.totalReclaimedHistorically > 0
                ? "\(state.totalReclaimedHistorically.formattedBytes) freed across \(state.cleanupHistory.count) cleanups."
                : "Every cleanup, with what it freed.") {
        } content: {
            if state.cleanupHistory.isEmpty {
                EmptyStateView(symbol: "list.bullet.rectangle", title: "No cleanups yet",
                               message: "Each cleanup is recorded here with what it freed.")
            } else {
                ForEach(groupedByWeek, id: \.0) { weekTitle, entries in
                    SurfaceSection(weekTitle) {
                        Text(entries.reduce(0) { $0 + $1.reclaimedBytes }.formattedBytes)
                            .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } content: {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                            if i > 0 { RowDivider() }
                            row(for: entry)
                        }
                    }
                }
            }
        }
    }

    private func row(for entry: CleanupEntry) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kindLabel(entry.kind)).font(Theme.Font.bodyStrong)
                Text("\(entry.date.formatted(date: .abbreviated, time: .shortened))  ·  \(entry.itemCount) item\(entry.itemCount == 1 ? "" : "s")")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.reclaimedBytes.formattedBytes)
                .font(Theme.Font.bodyStrong.monospacedDigit())
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func kindLabel(_ kind: CleanupEntry.Kind) -> String {
        switch kind {
        case .deletion: "Cleanup"
        case .dedup: "Duplicates replaced with clones"
        case .uninstall: "App uninstalled"
        case .docker: "Docker cleanup"
        case .dockerBuilderCache: "Docker build cache"
        case .timeMachine: "Time Machine snapshots"
        case .devTerminal: "Developer tools"
        }
    }

    /// Entries grouped by start of week (Sunday/Monday according to user locale), newest first.
    private var groupedByWeek: [(String, [CleanupEntry])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: state.cleanupHistory) { entry -> Date in
            let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: entry.date)
            return cal.date(from: components) ?? entry.date
        }
        return grouped.sorted { $0.key > $1.key }.map { weekStart, entries in
            let label = "Week of " + weekStart.formatted(date: .abbreviated, time: .omitted)
            return (label, entries.sorted { $0.date > $1.date })
        }
    }
}

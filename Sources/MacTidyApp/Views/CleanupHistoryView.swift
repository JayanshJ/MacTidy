import SwiftUI
import CoreKit

/// Timeline of completed cleanups: grouped by calendar week, newest first.
/// Shows what was cleaned, when, how many items, and how much space was freed.
struct CleanupHistoryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cleanup History").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            Divider()

            if state.cleanupHistory.isEmpty {
                ContentUnavailableView(
                    "No cleanups yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("History will appear here after you run your first cleanup.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedByWeek, id: \.0) { weekTitle, entries in
                        Section {
                            ForEach(entries) { entry in
                                row(for: entry)
                            }
                        } header: {
                            HStack {
                                Text(weekTitle)
                                Spacer()
                                Text(entries.reduce(0) { $0 + $1.reclaimedBytes }.formattedBytes)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 400, idealHeight: 520)
    }

    private func row(for entry: CleanupEntry) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            badge(for: entry.kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.body)
                Text("\(entry.itemCount) item\(entry.itemCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.reclaimedBytes.formattedBytes)
                .font(.body.monospacedDigit().bold())
                .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func badge(for kind: CleanupEntry.Kind) -> some View {
        let (label, color, icon): (String, Color, String) = {
            switch kind {
            case .deletion: ("Cleanup", Theme.accent, "trash")
            case .dedup: ("Dedup", .purple, "doc.on.doc")
            case .uninstall: ("Uninstall", .red, "trash.slash")
            case .docker: ("Docker", .blue, "cylinder.split.1x2")
            case .dockerBuilderCache: ("Docker Cache", .cyan, "hammer")
            case .timeMachine: ("Time Machine", .orange, "clock.arrow.circlepath")
            case .devTerminal: ("Dev Terminal", .green, "terminal")
            }
        }()

        Label(label, systemImage: icon)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
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

import SwiftUI
import CoreKit

/// The System tab: manual, system-level reclaim actions that can't go through
/// the Trash (no undo). These are `ShellAction`s, not cleanup categories —
/// they never appear in the dashboard cleanup grid, the schedule picker, or
/// `ScheduledRunner`. Everything here requires an explicit confirmation.
///
/// Today: Time Machine local snapshots (tmutil). The structure is extensible
/// — future system-level actions (e.g. clearing APFS local snapshots beyond
/// TM) live here too.
struct SystemTab: View {
    @Environment(AppState.self) private var state
    @State private var snapshots: [TMSnapshot] = []
    @State private var isLoading = false
    @State private var pending: [any ShellAction] = []
    @State private var showSheet = false
    @State private var outcome: ShellActionOutcome?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    timeMachineCard
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showSheet) {
            ShellActionConfirmationSheet(
                title: "Delete Time Machine snapshots?",
                actions: pending,
                kind: .timeMachine,
                note: "Local snapshots are deleted immediately — this cannot be undone. macOS recreates them on its own backup schedule, so the space is reclaimed now and refilled as TM runs.",
                onCompleted: { Task { await loadSnapshots() } }
            )
        }
        .task { await loadSnapshots() }
    }

    private var header: some View {
        HStack {
            Label("System", systemImage: "internaldrive").font(.title2.bold())
            Spacer()
            Button { Task { await loadSnapshots() } } label: {
                if isLoading { ProgressView().controlSize(.small) }
                else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var timeMachineCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.accent)
                Text("Time Machine local snapshots").font(.headline)
                Spacer()
                if !snapshots.isEmpty {
                    Badge(text: "\(snapshots.count)", tint: Theme.accent)
                }
            }
            Text("Local snapshots live on your startup volume and can tie up tens of GB. macOS creates and expires them automatically; deleting one frees space immediately and TM recreates snapshots on its next run.")
                .font(.caption).foregroundStyle(.secondary)

            if isLoading && snapshots.isEmpty {
                ProgressView("Checking snapshots…")
            } else if snapshots.isEmpty {
                Label("No local snapshots.", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(snapshots) { snap in
                        HStack {
                            Image(systemName: "clock").foregroundStyle(.secondary)
                            Text(snap.date).font(.callout.monospaced())
                            Spacer()
                            Button("Delete") {
                                pending = [DeleteSnapshotAction(snapshot: snap)]
                                outcome = nil
                                showSheet = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .listStyle(.bordered)
                .frame(maxHeight: 240)

                Button {
                    pending = snapshots.map { DeleteSnapshotAction(snapshot: $0) }
                    outcome = nil
                    showSheet = true
                } label: {
                    Label("Delete all \(snapshots.count) snapshots", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Status.blocked)
                .controlSize(.small)
            }
        }
        .cardStyle()
    }

    private func loadSnapshots() async {
        isLoading = true
        let result = await Task.detached { TimeMachineScanner.listSnapshots() }.value
        await MainActor.run { snapshots = result; isLoading = false }
    }
}
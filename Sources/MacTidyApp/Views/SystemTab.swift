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
        Page("Snapshots",
             subtitle: "Time Machine keeps local snapshots on your startup disk. macOS expires them on its own; deleting one frees space now and cannot be undone.") {
            Button { Task { await loadSnapshots() } } label: {
                if isLoading { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        } content: {
            timeMachineCard
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

    @ViewBuilder
    private var timeMachineCard: some View {
        if isLoading && snapshots.isEmpty {
            ProgressView("Checking snapshots").frame(maxWidth: .infinity).padding(Theme.Spacing.xxl)
        } else if snapshots.isEmpty {
            EmptyStateView(symbol: "clock.arrow.circlepath", title: "No local snapshots",
                           message: "Nothing is being held by Time Machine on this disk right now.")
        } else {
            SurfaceSection("\(snapshots.count) local snapshot\(snapshots.count == 1 ? "" : "s")") {
                Button(role: .destructive) {
                    pending = snapshots.map { DeleteSnapshotAction(snapshot: $0) }
                    outcome = nil
                    showSheet = true
                } label: { Text("Delete All") }
                .buttonStyle(.link)
                .font(Theme.Font.caption)
            } content: {
                ForEach(Array(snapshots.enumerated()), id: \.element.id) { i, snap in
                    if i > 0 { RowDivider(inset: 48) }
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 20)
                        Text(snap.date).font(.system(size: 13, design: .monospaced))
                        Spacer()
                        Button("Delete") {
                            pending = [DeleteSnapshotAction(snapshot: snap)]
                            outcome = nil
                            showSheet = true
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                }
            }
        }
    }

    private func loadSnapshots() async {
        isLoading = true
        let result = await Task.detached { TimeMachineScanner.listSnapshots() }.value
        await MainActor.run { snapshots = result; isLoading = false }
    }
}
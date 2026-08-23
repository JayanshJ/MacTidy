import SwiftUI
import CoreKit

/// The one confirmation UI every destructive action goes through. Shows the
/// complete plan — every path plus the total — with the dry-run toggle
/// visible, then reports the outcome.
struct DeletionConfirmationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let title: String
    let plan: DeletionPlan
    var extraAllowedRoots: [URL] = []
    var kind: TrashRecord.Kind = .deletion
    /// Non-file uninstall steps (TCC reset, lsregister) shown as their own
    /// group and run after the files are trashed. Empty for non-uninstall
    /// actions.
    var uninstallActions: [UninstallAction] = []
    /// Optional one-line reasoning from the AI advisor (or the deterministic
    /// fallback), shown above the plan to explain why these items were picked.
    var reasoning: String? = nil
    var onCompleted: (DeletionOutcome) -> Void = { _ in }

    @State private var outcome: DeletionOutcome?
    @State private var actionOutcome: UninstallActionOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome {
                outcomeView(outcome)
            } else {
                planView
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private var planView: some View {
        @Bindable var state = state

        Text(title).font(.title2.bold())
        if let reasoning, !reasoning.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                Text(reasoning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        Text("\(plan.candidates.count) item\(plan.candidates.count == 1 ? "" : "s") · \(plan.totalBytes.formattedBytes) will be moved to the Trash. Nothing is permanently deleted — restore from the Trash to undo.")
            .foregroundStyle(.secondary)

        List {
            if !uninstallActions.isEmpty {
                Section("Privacy & system cleanup") {
                    ForEach(uninstallActions) { action in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: action.kind.icon)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.kind.rawValue).fontWeight(.medium)
                                Text(action.kind.explanation)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(action.target)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                }
            }
            Section("Files to trash (\(plan.candidates.count))") {
                ForEach(plan.candidates) { candidate in
                    HStack {
                        Text(candidate.url.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(candidate.url.path)
                        Spacer()
                        Text(candidate.sizeBytes.formattedBytes)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.bordered)

        Toggle(isOn: $state.dryRun) {
            VStack(alignment: .leading) {
                Text("Dry run")
                Text("Log what would be trashed without touching anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(state.dryRun ? "Preview (Dry Run)" : "Move to Trash") { execute() }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty && uninstallActions.isEmpty)
        }
    }

    private func execute() {
        // Non-throwing: policy violations come back as per-item skipped
        // records in the outcome rather than aborting the whole plan.
        let result = state.execute(plan, extraAllowedRoots: extraAllowedRoots, kind: kind)
        // Run the non-file uninstall actions (TCC reset, lsregister) — only
        // meaningful for real passes; dry runs report a dry-run result.
        if !uninstallActions.isEmpty {
            actionOutcome = AppUninstaller.performActions(uninstallActions, dryRun: state.dryRun)
        }
        outcome = result
    }

    @ViewBuilder
    private func outcomeView(_ outcome: DeletionOutcome) -> some View {
        Label(
            outcome.dryRun
                ? "Dry run — nothing was touched"
                : "Moved \(outcome.trashed.count) item\(outcome.trashed.count == 1 ? "" : "s") to Trash",
            systemImage: outcome.dryRun ? "eye" : "checkmark.circle"
        )
        .font(.title2.bold())

        Text(outcome.dryRun
             ? "\(outcome.trashed.count) item(s) totalling \(outcome.reclaimedBytes.formattedBytes) would be trashed."
             : "\(outcome.reclaimedBytes.formattedBytes) reclaimable once you empty the Trash.")
            .foregroundStyle(.secondary)

        List {
            ForEach(outcome.trashed) { record in
                Label(record.original.path, systemImage: outcome.dryRun ? "eye" : "trash")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let actionOutcome, !actionOutcome.results.isEmpty {
                Section("Privacy & system cleanup") {
                    actionOutcomeRows(actionOutcome)
                }
            }
            if !outcome.skipped.isEmpty {
                Section("Skipped (left in place)") {
                    ForEach(outcome.skipped) { record in
                        VStack(alignment: .leading) {
                            Text(record.url.path).lineLimit(1).truncationMode(.head)
                            Text(record.reason).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .listStyle(.bordered)

        HStack {
            Spacer()
            Button("Done") {
                onCompleted(outcome)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func actionOutcomeRows(_ outcome: UninstallActionOutcome) -> some View {
        ForEach(outcome.results) { result in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.succeeded
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.succeeded ? Theme.Status.good : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.action.kind.rawValue).fontWeight(.medium)
                    Text(result.message)
                        .font(.caption)
                        .foregroundStyle(result.succeeded ? Color.secondary : Color.orange)
                }
            }
        }
    }
}

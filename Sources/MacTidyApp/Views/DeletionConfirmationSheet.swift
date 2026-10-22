import SwiftUI
import CoreKit

/// The one confirmation UI every destructive action goes through. Shows the
/// complete plan — every path plus the total — then reports the outcome.
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
    @State private var conflicts: [RunningAppConflict] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if let outcome {
                outcomeView(outcome)
            } else {
                planView
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 600, height: 540)
        .background(Theme.canvas)
        .task {
            // Re-check while the sheet is open so quitting the app clears the warning.
            while !Task.isCancelled, outcome == nil {
                let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                let found = RunningAppGuard.conflicts(for: plan.candidates.map(\.url), runningBundleIDs: running)
                if found != conflicts { conflicts = found }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func quit(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    }

    @ViewBuilder
    private var planView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title).font(.system(size: 17, weight: .semibold))
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(plan.totalBytes.formattedBytes).font(.system(size: 32, weight: .semibold).monospacedDigit())
                Text("in \(plan.candidates.count) item\(plan.candidates.count == 1 ? "" : "s")")
                    .font(Theme.Font.body).foregroundStyle(.secondary)
            }
            Text("Everything goes to the Trash, so you can put it back. MacTidy re-checks each path against its safety rules before moving it.")
                .font(Theme.Font.caption).foregroundStyle(.secondary)
            if let reasoning, !reasoning.isEmpty {
                Label(reasoning, systemImage: "wand.and.stars")
                    .font(Theme.Font.body)
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }

        ForEach(conflicts) { conflict in
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.caution)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(conflict.appName) is open").font(Theme.Font.bodyStrong)
                    Text(conflict.reason).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit \(conflict.appName)") { quit(conflict.bundleID) }
                    .help("Asks \(conflict.appName) to quit normally, so it can save your work.")
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Status.caution.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !uninstallActions.isEmpty {
                    SurfaceSection("Also on uninstall") {
                        ForEach(Array(uninstallActions.enumerated()), id: \.element.id) { i, action in
                            if i > 0 { RowDivider(inset: 48) }
                            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                                Image(systemName: action.kind.icon).foregroundStyle(.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.kind.rawValue).font(Theme.Font.bodyStrong)
                                    Text(action.kind.explanation).font(Theme.Font.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.md)
                        }
                    }
                }
                SurfaceSection("Items") {
                    ForEach(Array(plan.candidates.enumerated()), id: \.element.id) { i, candidate in
                        if i > 0 { RowDivider(inset: 48) }
                        HStack(spacing: Theme.Spacing.md) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                                .resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.url.lastPathComponent).font(Theme.Font.bodyStrong).lineLimit(1)
                                Text(candidate.url.deletingLastPathComponent().path)
                                    .font(Theme.Font.caption).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            .help(candidate.url.path)
                            Spacer()
                            Text(candidate.sizeBytes.formattedBytes)
                                .font(Theme.Font.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.sm)
                    }
                }
            }
        }

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(kind == .uninstall ? "Uninstall" : "Move to Trash") { execute() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty && uninstallActions.isEmpty)
        }
        .controlSize(.large)
    }

    private func execute() {
        if !uninstallActions.isEmpty {
            actionOutcome = AppUninstaller.performActions(uninstallActions)
        }
        Task { @MainActor in
            let result = await state.execute(plan, extraAllowedRoots: extraAllowedRoots, kind: kind)
            outcome = result
        }
    }

    @ViewBuilder
    private func outcomeView(_ outcome: DeletionOutcome) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Image(systemName: outcome.skipped.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(outcome.skipped.isEmpty ? Theme.accent : Theme.Status.caution)
            Text("\(outcome.reclaimedBytes.formattedBytes) moved to the Trash")
                .font(.system(size: 22, weight: .semibold))
            Text("\(outcome.trashed.count) item\(outcome.trashed.count == 1 ? "" : "s"). The space comes back when you empty the Trash, and anything can be restored until then.")
                .font(Theme.Font.body).foregroundStyle(.secondary)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !outcome.skipped.isEmpty {
                    SurfaceSection("Left in place") {
                        ForEach(Array(outcome.skipped.enumerated()), id: \.element.id) { i, record in
                            if i > 0 { RowDivider() }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.url.path).font(Theme.Font.body).lineLimit(1).truncationMode(.head)
                                Text(record.reason).font(Theme.Font.caption).foregroundStyle(Theme.Status.caution)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.sm)
                        }
                    }
                }
                if let actionOutcome, !actionOutcome.results.isEmpty {
                    SurfaceSection("Uninstall steps") {
                        actionOutcomeRows(actionOutcome)
                    }
                }
                if !outcome.trashed.isEmpty {
                    SurfaceSection("Moved to the Trash") {
                        ForEach(Array(outcome.trashed.enumerated()), id: \.element.id) { i, record in
                            if i > 0 { RowDivider() }
                            Text(record.original.path)
                                .font(Theme.Font.body).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Spacing.lg)
                                .padding(.vertical, Theme.Spacing.sm)
                        }
                    }
                }
            }
        }

        HStack {
            Spacer()
            Button("Done") {
                onCompleted(outcome)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private func actionOutcomeRows(_ outcome: UninstallActionOutcome) -> some View {
        ForEach(outcome.results) { result in
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

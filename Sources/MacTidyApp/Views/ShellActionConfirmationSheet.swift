import SwiftUI
import CoreKit

/// A generic, reusable confirmation sheet for `ShellAction`s — the
/// non-Trash-undoable destructive path used by Docker, Time Machine, and the
/// Docker builder cache. Shows each action's literal command (verbatim) and a
/// red "cannot be undone" warning, then runs the batch through
/// `AppState.executeShellActions`. Per-item fail-closed: a failed action is
/// reported with real stderr and does not abort the rest.
///
/// This is the factored-out sibling of `DockerActionConfirmationSheet`; the
/// Docker sheet keeps its volumes toggle because that affects the actions
/// themselves, not just confirmation.
struct ShellActionConfirmationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let title: String
    let actions: [any ShellAction]
    let kind: CleanupEntry.Kind
    let note: String?
    var onCompleted: () -> Void = {}

    @State private var outcome: ShellActionOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome { outcomeView(outcome) } else { planView }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private var planView: some View {
        Text(title).font(.title2.bold())
        Label("This cannot be undone — these actions do not go through the Trash.",
              systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout.weight(.medium))

        if let note {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }

        List {
            Section("Commands (\(actions.count))") {
                ForEach(actions, id: \.id) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.displayName).fontWeight(.medium)
                        Text(action.commandSummary)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .listStyle(.bordered)
        .frame(maxHeight: .infinity)

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Run") { execute() }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
                .disabled(actions.isEmpty)
        }
    }

    private func execute() {
        outcome = state.executeShellActions(actions, kind: kind)
    }

    @ViewBuilder
    private func outcomeView(_ outcome: ShellActionOutcome) -> some View {
        Label("Ran \(outcome.succeeded.count) action(s) · ≈ \(outcome.reclaimedBytes.formattedBytes)",
              systemImage: "checkmark.circle")
            .font(.title2.bold())
        List {
            if !outcome.succeeded.isEmpty {
                Section("Succeeded") {
                    ForEach(outcome.succeeded, id: \.id) { a in
                        Label(a.displayName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Status.good)
                    }
                }
            }
            if !outcome.failed.isEmpty {
                Section("Failed") {
                    ForEach(outcome.failed, id: \.id) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.action.displayName).fontWeight(.medium)
                            Text(f.message)
                                .font(.caption.monospaced())
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .listStyle(.bordered)
        .frame(maxHeight: .infinity)

        HStack {
            Spacer()
            Button("Done") {
                onCompleted()
                dismiss()
            }.keyboardShortcut(.defaultAction)
        }
    }
}
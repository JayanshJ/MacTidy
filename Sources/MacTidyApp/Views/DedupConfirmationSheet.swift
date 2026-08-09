import SwiftUI
import CoreKit

/// Confirmation for clone-based dedup. Different from deletion: every path
/// keeps working afterwards, extra copies just stop occupying their own
/// blocks. The replaced originals still go to the Trash for undo.
struct DedupConfirmationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    /// Only sets that actually waste space (more than one physical group).
    let sets: [DuplicateSet]
    let extraAllowedRoots: [URL]
    var onCompleted: (_ dryRun: Bool) -> Void = { _ in }

    private struct Summary {
        let dryRun: Bool
        var deduplicated: [TrashedRecord] = []
        var skipped: [SkippedRecord] = []
        var reclaimedBytes: Int64 = 0
    }

    @State private var summary: Summary?

    private var totalReclaimable: Int64 { sets.reduce(0) { $0 + $1.wastedBytes } }
    private var totalCopies: Int {
        sets.reduce(0) { $0 + $1.physicalGroups.dropFirst().reduce(0) { $0 + $1.count } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary {
                summaryView(summary)
            } else {
                planView
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
    }

    @ViewBuilder
    private var planView: some View {
        @Bindable var state = state

        Text("Deduplicate \(sets.count) set\(sets.count == 1 ? "" : "s")?")
            .font(.title2.bold())
        Text("""
        \(totalCopies) extra cop\(totalCopies == 1 ? "y" : "ies") will be replaced by APFS \
        clones of the kept file — every path keeps working with identical content, \
        but the data is stored once, freeing \(totalReclaimable.formattedBytes). \
        The replaced files' original bytes go to the Trash.
        """)
        .foregroundStyle(.secondary)

        List(sets) { set in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.physicalGroups.first?.first?.url.lastPathComponent ?? "—")
                        .lineLimit(1)
                    Text("\(set.files.count) copies · keeps \(set.physicalGroups.first?.first?.url.path ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Text(set.wastedBytes.formattedBytes)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.bordered)

        Toggle(isOn: $state.dryRun) {
            VStack(alignment: .leading) {
                Text("Dry run")
                Text("Log what would be deduplicated without touching anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(state.dryRun ? "Preview (Dry Run)" : "Deduplicate") { execute() }
                .keyboardShortcut(.defaultAction)
                .disabled(sets.isEmpty)
        }
    }

    private func execute() {
        // Non-throwing: per-set policy violations come back as skipped records.
        var result = Summary(dryRun: state.dryRun)
        for set in sets {
            let outcome = state.deduplicate(set, extraAllowedRoots: extraAllowedRoots)
            result.deduplicated += outcome.deduplicated
            result.skipped += outcome.skipped
            result.reclaimedBytes += outcome.reclaimedBytes
        }
        summary = result
    }

    @ViewBuilder
    private func summaryView(_ summary: Summary) -> some View {
        Label(
            summary.dryRun
                ? "Dry run — nothing was touched"
                : "Deduplicated \(summary.deduplicated.count) cop\(summary.deduplicated.count == 1 ? "y" : "ies")",
            systemImage: summary.dryRun ? "eye" : "checkmark.circle"
        )
        .font(.title2.bold())

        Text(summary.dryRun
             ? "\(summary.reclaimedBytes.formattedBytes) would be freed, with no file deleted."
             : "\(summary.reclaimedBytes.formattedBytes) freed once you empty the Trash. All file paths still work.")
            .foregroundStyle(.secondary)

        List {
            ForEach(summary.deduplicated) { record in
                Label(record.original.path,
                      systemImage: summary.dryRun ? "eye" : "doc.on.doc")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if !summary.skipped.isEmpty {
                Section("Skipped (left untouched)") {
                    ForEach(summary.skipped) { record in
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
                onCompleted(summary.dryRun)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

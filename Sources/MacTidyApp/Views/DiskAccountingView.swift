import SwiftUI
import CoreKit

struct DiskAccountingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report: DiskAccounting?
    init(preview: DiskAccounting? = nil) { _report = State(initialValue: preview) }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Where disk space goes").font(Theme.Font.section)
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        ForEach(report.parts) { part in row(part.name, part.bytes.formattedBytes) }
                        if let other = report.unaccountedBytes {
                            row("Other data, snapshots and unreadable files", other.formattedBytes)
                        }
                        if let free = report.physicalFree { row("Free blocks now", free.formattedBytes) }
                        if let purgeable = report.potentiallyPurgeable {
                            Text("macOS may make another \(purgeable.formattedBytes) available, including purgeable space. This overlaps used storage; it is not extra cleanup.")
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        if let count = report.snapshotCount {
                            Text("\(count) local Time Machine snapshot\(count == 1 ? "" : "s"). Their shared size cannot be inferred by adding file sizes.")
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        Text("Readable-file estimates. Full Disk Access improves coverage. Hard links and APFS clones can share blocks, so folder sizes may exceed physical use. The remainder includes normal macOS data and is not a cleanup recommendation. System memory files, including sleepimage, belong to macOS.")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Measuring readable folders…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Spacing.xl).frame(width: 620, height: 460).background(Theme.canvas)
        .task {
            guard !SnapshotHarness.isActive else { return }
            report = await Task.detached(priority: .utility) { DiskAccounting.scan() }.value
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }
    }
}

import SwiftUI
import CoreKit

struct DiskAccountingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var report: DiskAccounting?
    init(preview: DiskAccounting? = nil) { _report = State(initialValue: preview) }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Where disk space goes").font(Theme.Font.section)
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        ForEach(report.parts) { part in
                            row(part.name, part.bytes.formattedBytes, action: action(for: part.destination))
                        }
                        if let other = report.unaccountedBytes {
                            row("Other data, snapshots and unreadable files", other.formattedBytes,
                                action: ("Snapshots", { go(.timeMachine) }))
                        }
                        if let free = report.physicalFree { row("Free blocks now", free.formattedBytes) }
                        let elsewhere = state.elsewhereItems.reduce(0) { $0 + $1.sizeBytes }
                        if elsewhere > 0 {
                            HStack {
                                Text("The rows above include \(elsewhere.formattedBytes) that other apps or settings manage (games, Docker, VMs, messages, iCloud).")
                                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Managed elsewhere") {
                                    dismiss()
                                    state.section = .cleanup
                                    state.drilledCategory = nil
                                    state.showingElsewhere = true
                                }
                                .buttonStyle(.link).font(Theme.Font.caption)
                            }
                        }
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

    private func action(for destination: DiskAccounting.Part.Destination?) -> (String, () -> Void)? {
        switch destination {
        case .folder(let url):
            ("Disk Map", { dismiss(); state.openInDiskMap(url) })
        case .trash:
            ("Trash", { go(.trash) })
        case nil:
            nil
        }
    }

    private func go(_ item: SidebarItem) {
        dismiss()
        state.section = item
    }

    private func row(_ title: String, _ value: String, action: (String, () -> Void)? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
            if let action {
                Button { action.1() } label: {
                    Label(action.0, systemImage: "arrow.right.circle").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.link).font(Theme.Font.caption)
                .frame(width: 96, alignment: .trailing)
            } else {
                Color.clear.frame(width: 96, height: 1)
            }
        }
    }
}

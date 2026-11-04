import SwiftUI
import CoreKit

struct TargetCleanupView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var target = "5"
    @State private var proposal: TargetCleanup?
    @State private var selection = Set<UUID>()
    @State private var plan: DeletionPlan?
    @State private var building = false

    init(preview: TargetCleanup? = nil) {
        _proposal = State(initialValue: preview)
        _selection = State(initialValue: preview?.initialSelection ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Free up space").font(Theme.Font.section)
            HStack {
                Text("Target")
                TextField("GB", text: $target).frame(width: 90)
                Text("GB")
                Button("Build plan") { build() }
                    .disabled(TargetCleanup.bytes(fromGB: target) == nil || building)
                if building { ProgressView().controlSize(.small) }
            }
            Text("Lowest cost first: rebuildable caches, downloads, reinstalls, then personal data. Review items need your selection. Sizes are estimates; space returns after emptying Trash.")
                .font(Theme.Font.caption).foregroundStyle(.secondary)
            if let proposal {
                let selected = proposal.items.filter { selection.contains($0.id) }
                let bytes = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
                Text("Selected \(bytes.formattedBytes) of \(proposal.targetBytes.formattedBytes)")
                    .font(Theme.Font.bodyStrong)
                if proposal.proposedBytes < proposal.targetBytes {
                    Text("The scan found only \(proposal.proposedBytes.formattedBytes) eligible for review. Scan again or choose a smaller target.")
                        .font(Theme.Font.caption).foregroundStyle(.orange)
                } else if bytes < proposal.targetBytes {
                    Text("Review and select more items to reach the target. Nothing is added automatically.")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        ForEach(proposal.items) { item in
                            Toggle(isOn: Binding(get: { selection.contains(item.id) }, set: {
                                if $0 { selection.insert(item.id) } else { selection.remove(item.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(item.url.lastPathComponent) · \(item.sizeBytes.formattedBytes)")
                                    Text(item.url.path).font(Theme.Font.caption).foregroundStyle(.secondary)
                                    Text(TargetCleanup.cost(item).explanation + (item.isPreselectable ? "" : " Requires review."))
                                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Review \(selected.count) selected items…") { plan = DeletionPlan(items: selected) }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
                }
            } else {
                Spacer()
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Spacing.xl).frame(width: 660, height: 560).background(Theme.canvas)
        .onChange(of: target) { _, _ in proposal = nil; selection = [] }
        .sheet(item: $plan) { plan in
            DeletionConfirmationSheet(title: "Move this plan to the Trash?", plan: plan) { _ in
                proposal = nil; selection = []
            }
        }
    }

    private func build() {
        guard let bytes = TargetCleanup.bytes(fromGB: target) else { return }
        let results = state.categoryResults, roots = state.extraAllowedRoots, input = target
        building = true
        Task {
            let result = await Task.detached {
                TargetCleanup(results: results, targetBytes: bytes, policy: SafePathPolicy(extraAllowedRoots: roots))
            }.value
            building = false
            guard target == input else { return }
            proposal = result
            selection = result.initialSelection
        }
    }
}

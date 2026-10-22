import SwiftUI
import CoreKit

/// Every reclaimable category, then one category's items with selection.
struct CleanupView: View {
    @Environment(AppState.self) private var state
    @State private var selection = Set<UUID>()
    @State private var sheetPlan: DeletionPlan?
    @State private var sheetTitle = "Move selected items to the Trash?"
    @State private var showNodeInspector = false
    @State private var reviewing = false
    @State private var reviewError: String?

    var body: some View {
        Group {
            if let category = state.drilledCategory {
                CategoryDetail(category: category, selection: $selection,
                               reviewing: reviewing, reviewError: reviewError,
                               onBack: { withAnimation(Theme.ease) { state.drilledCategory = nil } },
                               onReview: { items in Task { await review(items, category) } },
                               onInspectNode: { showNodeInspector = true },
                               onTrash: { items in
                                   sheetTitle = "Move \(items.count) item\(items.count == 1 ? "" : "s") to the Trash?"
                                   sheetPlan = DeletionPlan(items: items)
                               })
            } else {
                categoryList
            }
        }
        .onChange(of: state.drilledCategory) { _, _ in
            selection.removeAll()
            reviewError = nil
        }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: sheetTitle, plan: plan) { _ in
                selection.removeAll()
                Task { await state.rescanCategories() }
            }
        }
        .sheet(isPresented: $showNodeInspector) { NodePackagesInspector() }
    }

    // MARK: Category list

    private var categoryList: some View {
        let nonEmpty = state.categoryResults.filter { $0.totalBytes > 0 }.sorted { $0.totalBytes > $1.totalBytes }
        let safe = nonEmpty.filter(\.category.isPreselectable)
        let review = nonEmpty.filter { !$0.category.isPreselectable }
        let safeItems = state.categoryResults.flatMap(\.items).filter(\.isPreselectable)
        let maxBytes = nonEmpty.first?.totalBytes ?? 1

        return Page("Cleanup",
                    subtitle: "\(state.totalReclaimable.formattedBytes) across \(nonEmpty.count) categories. Everything goes to the Trash, so it can be put back.") {
            Button { showNodeInspector = true } label: { Label("Node Packages", systemImage: "shippingbox") }
                .help("Find orphaned and unused npm packages and prune them safely.")
            Button("Clean Safe Items") {
                sheetTitle = "Clean everything that's safe?"
                sheetPlan = DeletionPlan(items: safeItems)
            }
            .buttonStyle(.borderedProminent)
            .disabled(safeItems.isEmpty)
        } content: {
            if nonEmpty.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "Nothing to clean",
                               message: "No reclaimable caches or build output right now. Scan again after building projects or installing apps.")
            } else {
                if state.trashBytes >= TrashNudgeCard.threshold { TrashNudgeCard() }
                if !safe.isEmpty {
                    section("Safe to remove", footer: "Caches and build output that rebuild on their own.",
                            results: safe, maxBytes: maxBytes)
                }
                if !review.isEmpty {
                    section("Worth a look", footer: "Personal files, app data and things that are slow to rebuild. Never selected for you.",
                            results: review, maxBytes: maxBytes)
                }
            }
        }
    }

    private func section(_ title: String, footer: String, results: [CategoryResult], maxBytes: Int64) -> some View {
        SurfaceSection(title, footer: footer) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { RowDivider(inset: 48) }
                Button {
                    withAnimation(Theme.ease) { state.drilledCategory = result.category }
                } label: {
                    CategoryRow(result: result, maxBytes: maxBytes)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    // MARK: AI review

    private func review(_ items: [ScanItem], _ category: CoreKit.Category) async {
        reviewing = true
        reviewError = nil
        defer { reviewing = false }
        do {
            let verdicts = try await state.explainBatchThrowing(items: items)
            var map: [UUID: BatchVerdict] = [:]
            for v in verdicts { map[v.id] = v }
            state.batchVerdicts = map
            state.batchVerdictsCategory = category
            if verdicts.isEmpty {
                reviewError = "The model returned no verdicts."
            } else if verdicts.allSatisfy({ $0.verdict == nil && $0.summary.isEmpty }) {
                reviewError = "The model replied without usable verdicts. It may not support this request format."
            }
        } catch {
            reviewError = error.localizedDescription
            state.batchVerdicts = [:]
            state.batchVerdictsCategory = nil
        }
    }
}

/// One category's items: header, list, selection footer.
private struct CategoryDetail: View {
    @Environment(AppState.self) private var state
    let category: CoreKit.Category
    @Binding var selection: Set<UUID>
    let reviewing: Bool
    let reviewError: String?
    let onBack: () -> Void
    let onReview: ([ScanItem]) -> Void
    let onInspectNode: () -> Void
    let onTrash: ([ScanItem]) -> Void

    var body: some View {
        let result = state.categoryResults.first { $0.category == category }
        let items = result?.items ?? []
        let selected = items.filter { selection.contains($0.id) }
        let allSelected = !items.isEmpty && items.allSatisfy { selection.contains($0.id) }

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Button(action: onBack) {
                    Label("Cleanup", systemImage: "chevron.left").font(Theme.Font.body)
                }
                .buttonStyle(.link)
                PageHeader(title: category.displayName,
                           subtitle: "\(items.count) item\(items.count == 1 ? "" : "s")  ·  \(result?.totalBytes.formattedBytes ?? "0 bytes")") {
                    if category == .nodeModules {
                        Button(action: onInspectNode) { Label("Analyze Packages", systemImage: "shippingbox") }
                    }
                    if !items.isEmpty && state.aiConfig.provider != .none {
                        Button { onReview(items) } label: {
                            if reviewing {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reviewing") }
                            } else {
                                Label("Review with AI", systemImage: "wand.and.stars")
                            }
                        }
                        .disabled(reviewing)
                    }
                    if !items.isEmpty {
                        Button(allSelected ? "Deselect All" : "Select All") {
                            if allSelected { selection.removeAll() } else { selection = Set(items.map(\.id)) }
                        }
                    }
                }
                Text(category.explanation)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: 640, alignment: .leading)
                if let reviewError {
                    Label(reviewError, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Status.caution)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Theme.hairline).frame(height: 1)
            if items.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "Nothing here now")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        ForEach(groups(items, byProject: category == .nodeModules)) { group in
                            groupSection(group, titled: category == .nodeModules)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.vertical, Theme.Spacing.xl)
                }
            }
            SelectionFooter(selectedCount: selected.count,
                            selectedBytes: selected.reduce(0) { $0 + $1.sizeBytes },
                            buttonTitle: "Move to Trash…",
                            disabled: false) { onTrash(selected) }
        }
        .background(Theme.canvas)
    }

    /// node_modules grouped by project, with per-project select-all.
    private struct ItemGroup: Identifiable {
        let id: String
        let items: [ScanItem]
        var bytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    }

    /// One group for a plain category; one per project for node_modules.
    private func groups(_ items: [ScanItem], byProject: Bool) -> [ItemGroup] {
        guard byProject else { return [ItemGroup(id: "", items: items)] }
        return Dictionary(grouping: items) { $0.detail ?? "Other" }
            .map { ItemGroup(id: $0.key, items: $0.value.sorted { $0.sizeBytes > $1.sizeBytes }) }
            .sorted { $0.bytes > $1.bytes }
    }

    private func groupSection(_ group: ItemGroup, titled: Bool) -> some View {
        let all = group.items.allSatisfy { selection.contains($0.id) }
        return SurfaceSection(titled ? group.id : nil) {
            if titled {
                Text(group.bytes.formattedBytes)
                    .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(all ? "Deselect" : "Select") {
                    for item in group.items {
                        if all { selection.remove(item.id) } else { selection.insert(item.id) }
                    }
                }
                .buttonStyle(.link)
                .font(Theme.Font.caption)
            }
        } content: {
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider(inset: 70) }
                ScanItemRow(item: item, selection: $selection, batchVerdict: state.batchVerdicts[item.id])
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
            }
        }
    }
}

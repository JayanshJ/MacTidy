import SwiftUI
import CoreKit

/// The post-scan home: every reclaimable category and every tool visible at
/// once. A tab bar switches between Cleanup (category cards grid), Uninstaller,
/// Startup Items, and Duplicates — all in the new design system. Drilling
/// into a category shows its items with multi-select and Trash, like the old
/// Disk view but redesigned.
struct DashboardView: View {
    @Environment(AppState.self) private var state
    @State private var tab: DashboardTab = .cleanup
    @State private var drilledCategory: CoreKit.Category?
    @State private var sheetPlan: DeletionPlan?
    @State private var sheetPlanIsCleanAll = false
    @State private var selection = Set<UUID>()
    @State private var showNodeInspector = false
    /// Per-item AI batch verdicts keyed by `ScanItem.id`, populated by the
    /// "Review with AI" button on the category drill-in header. Rendered inline
    /// on `ScanItemRow` — no new popup surface.
    @State private var batchVerdicts: [UUID: BatchVerdict] = [:]
    @State private var reviewAll = false
    /// Surfaces why a "Review with AI" batch pass failed, so it isn't a silent
    /// no-op (spinner stops, nothing renders). Mirrors CategoryCleanupView.
    @State private var reviewError: String?

    enum DashboardTab: String, CaseIterable, Identifiable {
        case insights = "Insights"
        case cleanup = "Cleanup"
        case byApp = "Storage by App"
        case uninstaller = "Uninstaller"
        case startup = "Startup"
        case docker = "Docker"
        case duplicates = "Duplicates"
        case system = "System"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .insights: "sparkles"
            case .cleanup: "square.grid.2x2"
            case .byApp: "person.crop.square"
            case .uninstaller: "trash.slash"
            case .startup: "power"
            case .docker: "cylinder.split.1x2"
            case .duplicates: "doc.on.doc"
            case .system: "internaldrive"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if state.isScanningCategories {
                ContentUnavailableView("Scanning…", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(
                title: sheetPlanTitle,
                plan: plan,
                kind: sheetPlanKind
            ) { _ in
                selection.removeAll()
                Task { await state.rescanCategories() }
            }
        }
        .sheet(isPresented: $showNodeInspector) {
            NodePackagesInspector()
        }
    }

    /// Segmented tab bar with icons + labels, teal-tinted selection.
    private var tabBar: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(DashboardTab.allCases) { t in
                tabButton(t)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private func tabButton(_ t: DashboardTab) -> some View {
        let selected = tab == t
        Button {
            withAnimation(.snappy) {
                tab = t
                drilledCategory = nil
                selection.removeAll()
                batchVerdicts.removeAll()
                reviewError = nil
            }
        } label: {
            Label(t.rawValue, systemImage: t.icon)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : Color.secondary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Theme.accent.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .insights: InsightsTab()
        case .cleanup:
            if let cat = drilledCategory {
                categoryDetail(cat)
            } else {
                categoryGrid
            }
        case .byApp: StorageByAppTab()
        case .uninstaller: DashboardUninstaller()
        case .startup: DashboardStartup()
        case .docker: DashboardDocker()
        case .duplicates: DuplicatesView()
        case .system: SystemTab()
        }
    }

    // MARK: - Cleanup grid

    /// Grid of category cards. Each shows the category name, total bytes, a
    /// proportion bar, item count, and a suggest-only badge where relevant.
    /// Tapping drills into the category's items. Zero-byte categories are
    /// filtered out so the grid doesn't waste space on cards with nothing to
    /// reclaim; when every category is empty, a compact empty state replaces
    /// the header + grid so the tab doesn't waste vertical space on disabled
    /// chrome.
    private var categoryGrid: some View {
        Group {
            if state.categoryResults.allSatisfy({ $0.items.isEmpty }) {
                ContentUnavailableView(
                    "Nothing to clean",
                    systemImage: "checkmark.seal",
                    description: Text("MacTidy didn't find any reclaimable caches or build artifacts. Rescan after installing apps or building projects.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        header
                        if state.trashBytes >= TrashNudgeCard.threshold {
                            TrashNudgeCard()
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.md)],
                                  spacing: Theme.Spacing.md) {
                            ForEach(state.categoryResults.filter { $0.totalBytes > 0 }) { result in
                                categoryCard(result)
                            }
                        }
                    }
                    .padding(Theme.Spacing.xl)
                }
            }
        }
    }

    /// The dashboard header: total reclaimable + dry-pass banner + the one-
    /// click clean-all-safe action.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(state.totalReclaimable.formattedBytes)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
            Text("reclaimable")
                .font(.title3).foregroundStyle(.secondary)
            Spacer()
            Button { Task { await state.rescanCategories() } } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                showNodeInspector = true
            } label: {
                Label("Node Packages", systemImage: "shippingbox")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Find orphaned and unused npm packages across your Node projects, and run npm prune safely.")
            Button {
                sheetPlanIsCleanAll = true
                sheetPlan = DeletionPlan(items: allSafeItems)
            } label: {
                if allSafeItems.isEmpty {
                    Label("Clean All Safe", systemImage: "trash.circle.fill")
                } else {
                    Label("Clean All Safe · \(allSafeBytes.formattedBytes)",
                          systemImage: "trash.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(allSafeItems.isEmpty)
            .help("Trash every item in the safe categories (caches, build artifacts, old installers). Suggest-only categories like Downloads and large files are never included.")
        }
    }

    /// Every item across the categories that are safe to bulk-trash — i.e.
    /// `isPreselectable` categories. Suggest-only categories (Downloads,
    /// large files, app support, device backups) are deliberately excluded
    /// so one click never trashes something the user should review first.
    /// The plan still flows through SafePathPolicy + Trasher, so per-item
    /// safety is enforced on top of this.
    private var allSafeItems: [ScanItem] {
        state.categoryResults
            .filter { $0.category.isPreselectable }
            .flatMap(\.items)
    }

    private var allSafeBytes: Int64 {
        allSafeItems.reduce(0) { $0 + $1.sizeBytes }
    }

    private func categoryCard(_ result: CategoryResult) -> some View {
        let max = state.categoryResults.map(\.totalBytes).max() ?? 0
        return Button {
            withAnimation(.snappy) { drilledCategory = result.category }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text(result.category.displayName).font(.headline).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                Text(result.totalBytes.formattedBytes)
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(result.totalBytes > 0 ? .primary : .tertiary)
                SizeBar(fraction: max > 0 ? Double(result.totalBytes) / Double(max) : 0,
                        fillsWidth: true)
                HStack(spacing: Theme.Spacing.xs) {
                    Text("\(result.items.count) item\(result.items.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    if !result.category.isPreselectable {
                        Badge(text: "Suggest-only", tint: Theme.Status.caution)
                    }
                    Spacer()
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category drill-in

    /// The items inside one category, with multi-select + Trash — the old
    /// Disk cleanup list, redesigned.
    private func categoryDetail(_ category: CoreKit.Category) -> some View {
        let result = state.categoryResults.first { $0.category == category }
        let items = result?.items ?? []
        let selected = items.filter { selection.contains($0.id) }
        return VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.snappy) { drilledCategory = nil }
                    batchVerdicts.removeAll()
                    reviewError = nil
                } label: {
                    Label("Categories", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Text(category.displayName).font(.title3.bold())
                Spacer()
                if category == .nodeModules {
                    Button { showNodeInspector = true } label: {
                        Label("Analyze packages", systemImage: "shippingbox")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Find orphaned and unused npm packages and run npm prune safely.")
                }
                if !items.isEmpty && state.aiConfig.provider != .none {
                    Button {
                        Task { await reviewCategoryWithAI(items: items) }
                    } label: {
                        if reviewAll {
                            HStack { ProgressView().controlSize(.small); Text("Reviewing…") }
                        } else {
                            Label("Review with AI", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(reviewAll)
                    .help("Get a Safe / Review / Keep verdict for each item in one AI pass.")
                }
                if !items.isEmpty {
                    Button {
                        let allSelected = items.allSatisfy { selection.contains($0.id) }
                        selection.removeAll()
                        if !allSelected {
                            for item in items { selection.insert(item.id) }
                        }
                    } label: {
                        let allSelected = items.allSatisfy { selection.contains($0.id) }
                        Label(allSelected ? "Deselect All" : "Select All",
                              systemImage: allSelected ? "circle" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Text("\(items.count) item\(items.count == 1 ? "" : "s") · \(result?.totalBytes.formattedBytes ?? "0")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
            if let reviewError {
                Label(reviewError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)
            }
            Divider()
            if category == .nodeModules {
                nodeModulesList(items: items)
            } else {
                flatList(items: items, category: category)
            }
            SelectionFooter(
                selectedCount: selection.count,
                selectedBytes: selected.reduce(0) { $0 + $1.sizeBytes },
                buttonTitle: "Trash Selected…",
                disabled: false
            ) {
                sheetPlanIsCleanAll = false
                sheetPlan = DeletionPlan(items: selected)
            }
        }
    }

    /// node_modules grouped by parent project so the user isn't scrolling one
    /// flat list across every Node project. Each section is one project, with
    /// per-section select-all (grab a whole project at once) and the project's
    /// total node_modules bytes in the header.
    @ViewBuilder
    private func nodeModulesList(items: [ScanItem]) -> some View {
        let groups = Dictionary(grouping: items, by: { $0.detail ?? "Other" })
            .sorted { (lhs, rhs) in lhs.value.reduce(0) { $0 + $1.sizeBytes } > rhs.value.reduce(0) { $0 + $1.sizeBytes } }
        List {
            if items.isEmpty {
                Text("Nothing found").foregroundStyle(.tertiary)
            }
            ForEach(groups, id: \.key) { projectName, groupItems in
                Section {
                    ForEach(groupItems.sorted { $0.sizeBytes > $1.sizeBytes }) { item in
                        ScanItemRow(item: item, selection: $selection, batchVerdict: batchVerdicts[item.id])
                    }
                } header: {
                    HStack {
                        Text(projectName).font(.headline)
                        Spacer()
                        Text("≈ \(groupItems.reduce(0) { $0 + $1.sizeBytes }.formattedBytes)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button {
                            let allSelected = groupItems.allSatisfy { selection.contains($0.id) }
                            if allSelected {
                                for item in groupItems { selection.remove(item.id) }
                            } else {
                                for item in groupItems { selection.insert(item.id) }
                            }
                        } label: {
                            let allSelected = groupItems.allSatisfy { selection.contains($0.id) }
                            Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(allSelected ? Theme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func flatList(items: [ScanItem], category: CoreKit.Category) -> some View {
        List {
            Section {
                if items.isEmpty {
                    Text("Nothing found").foregroundStyle(.tertiary)
                }
                ForEach(items) { item in
                    ScanItemRow(item: item, selection: $selection, batchVerdict: batchVerdicts[item.id])
                }
            } footer: {
                Text(category.explanation)
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Sheet plumbing

    /// One AI pass over the drilled-in category's items, rendering
    /// Safe/Review/Keep inline on the rows. No new popup — verdicts decorate
    /// the existing list. Runs in the background; the user can keep browsing.
    private func reviewCategoryWithAI(items: [ScanItem]) async {
        reviewAll = true
        reviewError = nil
        defer { reviewAll = false }
        do {
            let verdicts = try await state.explainBatchThrowing(items: items)
            var map: [UUID: BatchVerdict] = [:]
            for v in verdicts { map[v.id] = v }
            batchVerdicts = map
            if verdicts.isEmpty {
                reviewError = "The model returned no verdicts."
            } else if verdicts.allSatisfy({ $0.verdict == nil && $0.summary.isEmpty }) {
                reviewError = "The model replied but with no parseable verdicts — it may be a reasoning model that needs more time, or one that doesn't support the tool-call format."
            }
        } catch {
            reviewError = error.localizedDescription
            batchVerdicts = [:]
        }
    }

    private var sheetPlanTitle: String {
        switch tab {
        case .insights, .cleanup:
            sheetPlanIsCleanAll ? "Clean all safe items?" : "Trash selected items?"
        case .byApp: "Trash selected items?"
        case .uninstaller: "Uninstall \(state.flowApps.first?.app.name ?? "app")?"
        case .startup, .docker, .duplicates, .system: "Trash selected items?"
        }
    }

    private var sheetPlanKind: TrashRecord.Kind {
        tab == .uninstaller ? .uninstall : .deletion
    }
}
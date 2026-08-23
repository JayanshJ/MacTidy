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
    @State private var sheetPlanReasoning: String?
    @State private var selection = Set<UUID>()
    @State private var aiIntent = ""
    @State private var aiThinking = false
    @State private var showNodeInspector = false

    enum DashboardTab: String, CaseIterable, Identifiable {
        case cleanup = "Cleanup"
        case byApp = "Storage by App"
        case uninstaller = "Uninstaller"
        case startup = "Startup"
        case duplicates = "Duplicates"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .cleanup: "square.grid.2x2"
            case .byApp: "person.crop.square"
            case .uninstaller: "trash.slash"
            case .startup: "power"
            case .duplicates: "doc.on.doc"
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
                kind: sheetPlanKind,
                reasoning: sheetPlanReasoning
            ) { outcome in
                if !outcome.dryRun {
                    selection.removeAll()
                    sheetPlanReasoning = nil
                    Task { await state.rescanCategories() }
                }
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
        case .cleanup:
            if let cat = drilledCategory {
                categoryDetail(cat)
            } else {
                categoryGrid
            }
        case .byApp: StorageByAppTab()
        case .uninstaller: DashboardUninstaller()
        case .startup: DashboardStartup()
        case .duplicates: DuplicatesView()
        }
    }

    // MARK: - Cleanup grid

    /// Grid of category cards. Each shows the category name, total bytes, a
    /// proportion bar, item count, and a suggest-only badge where relevant.
    /// Tapping drills into the category's items. When there's nothing to
    /// clean, a compact empty state replaces the header + grid so the tab
    /// doesn't waste vertical space on disabled chrome.
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
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.md)],
                                  spacing: Theme.Spacing.md) {
                            ForEach(state.categoryResults) { result in
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
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
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
            passBanner
            commandBar
        }
    }

    /// The natural-language AI command bar. Type an intent ("free up 15 GB",
    /// "clean Xcode stuff") and the configured advisor proposes a plan that
    /// opens in the existing confirmation sheet. Falls back to the
    /// deterministic ranking when no provider is configured or the call fails.
    private var commandBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(state.aiConfig.provider == .none
                                 ? AnyShapeStyle(.tertiary)
                                 : AnyShapeStyle(Theme.accent))
            TextField("Ask MacTidy to clean…  e.g. \"free up 10 GB\" or \"clean Xcode caches\"",
                      text: $aiIntent)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runAI() }
            if aiThinking {
                ProgressView().controlSize(.small)
            }
            Button {
                runAI()
            } label: {
                Label("Suggest", systemImage: "arrow.up.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(aiIntent.trimmingCharacters(in: .whitespaces).isEmpty || aiThinking)
            .help(state.aiConfig.provider == .none
                  ? "No AI provider configured — will use the built-in ranking. Add one in Settings."
                  : "Ask the configured AI model for a cleanup plan.")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.accent.opacity(0.06))
        )
    }

    private func runAI() {
        let intent = aiIntent.trimmingCharacters(in: .whitespaces)
        guard !intent.isEmpty else { return }
        aiThinking = true
        Task {
            let result = await state.aiPlan(for: intent)
            await MainActor.run {
                aiThinking = false
                sheetPlanIsCleanAll = false
                sheetPlanReasoning = result.reasoning
                sheetPlan = result.plan
            }
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

    private var passBanner: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: state.flowPass == .dry ? "eye" : "checkmark.shield")
            Text(state.flowPass == .dry
                 ? "Dry preview — nothing is trashed until you turn Dry Run off"
                 : "Real pass — items move to the Trash (undoable)")
                .font(.caption.bold())
            Spacer()
            if state.flowPass == .dry {
                Button("Run for real") {
                    state.startRealPass()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .foregroundStyle(state.flowPass == .dry ? .secondary : Theme.accent)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((state.flowPass == .dry ? Color.secondary : Theme.accent).opacity(0.1))
        )
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
                } label: {
                    Label("Categories", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Text(category.displayName).font(.title3.bold())
                Spacer()
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("\(items.count) item\(items.count == 1 ? "" : "s") · \(result?.totalBytes.formattedBytes ?? "0")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
            Divider()
            List {
                Section {
                    if items.isEmpty {
                        Text("Nothing found").foregroundStyle(.tertiary)
                    }
                    ForEach(items) { item in
                        ScanItemRow(item: item, selection: $selection)
                    }
                } footer: {
                    Text(category.explanation)
                        .font(.caption).foregroundStyle(.tertiary)
                }
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

    // MARK: - Sheet plumbing

    private var sheetPlanTitle: String {
        switch tab {
        case .cleanup:
            sheetPlanIsCleanAll ? "Clean all safe items?" : "Trash selected items?"
        case .byApp: "Trash selected items?"
        case .uninstaller: "Uninstall \(state.flowApps.first?.app.name ?? "app")?"
        case .startup, .duplicates: "Trash selected items?"
        }
    }

    private var sheetPlanKind: TrashRecord.Kind {
        tab == .uninstaller ? .uninstall : .deletion
    }
}
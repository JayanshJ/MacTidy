import SwiftUI
import CoreKit

struct DiskView: View {
    enum Mode: String, CaseIterable {
        case categories = "Cleanup"
        case explorer = "Biggest Directories"
    }

    @State private var mode: Mode = .categories

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            switch mode {
            case .categories: CategoryCleanupView()
            case .explorer: DirectoryExplorerView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Category cleanup

struct CategoryCleanupView: View {
    @Environment(AppState.self) private var state
    @State private var selection = Set<UUID>()
    @State private var sheetPlan: DeletionPlan?
    /// Per-item batch verdicts keyed by `ScanItem.id`. Populated by the
    /// category-level "Review with AI" button and rendered inline on rows.
    @State private var batchVerdicts: [UUID: BatchVerdict] = [:]
    @State private var reviewAll = false

    private var allItems: [ScanItem] {
        state.categoryResults.flatMap(\.items)
    }

    private var selectedItems: [ScanItem] {
        allItems.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.categoryResults.isEmpty {
                ContentUnavailableView {
                    Label("No scan yet", systemImage: "internaldrive")
                } description: {
                    Text("Scan the cleanup categories to see what's reclaimable.")
                } actions: {
                    Button(state.isScanningCategories ? "Scanning…" : "Scan Now") {
                        Task { await state.rescanCategories() }
                    }
                    .disabled(state.isScanningCategories)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Button("Select All Safe") {
                        selection = Set(
                            state.categoryResults
                                .filter(\.category.isPreselectable)
                                .flatMap(\.items)
                                .map(\.id)
                        )
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    if state.aiConfig.provider != .none {
                        Button {
                            Task { await reviewAllWithAI() }
                        } label: {
                            if reviewAll {
                                HStack { ProgressView().controlSize(.small); Text("Reviewing…") }
                            } else {
                                Label("Review all with AI", systemImage: "wand.and.stars")
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(reviewAll)
                        .help("Get a Safe / Review / Keep verdict for every item in one AI pass.")
                    }
                    Spacer()
                    Button {
                        Task { await state.rescanCategories() }
                    } label: {
                        if state.isScanningCategories {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(state.isScanningCategories)
                }
                .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
                Divider()
                List {
                    ForEach(state.categoryResults) { result in
                        categorySection(result)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                SelectionFooter(
                    selectedCount: selection.count,
                    selectedBytes: selectedItems.reduce(0) { $0 + $1.sizeBytes },
                    buttonTitle: "Trash Selected…",
                    disabled: false
                ) {
                    sheetPlan = DeletionPlan(items: selectedItems)
                }
            }
        }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Trash selected items?", plan: plan) { _ in
                selection.removeAll()
                Task { await state.rescanCategories() }
            }
        }
    }

    @ViewBuilder
    private func categorySection(_ result: CategoryResult) -> some View {
        Section {
            if result.items.isEmpty {
                Text("Nothing found").foregroundStyle(.tertiary)
            }
            ForEach(result.items) { item in
                ScanItemRow(item: item, selection: $selection, batchVerdict: batchVerdicts[item.id])
            }
        } header: {
            HStack {
                Text(result.category.displayName)
                if !result.category.isPreselectable {
                    Badge(text: "Suggest-only", tint: Theme.Status.caution)
                        .help("Build artifacts of possibly-active projects; check before trashing.")
                }
                Spacer()
                Text(result.totalBytes.formattedBytes).monospacedDigit()
            }
        } footer: {
            Text(result.category.explanation)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// One AI pass over every scanned item, rendering Safe/Review/Keep inline
    /// on the rows. No new popup — verdicts decorate the existing list. Runs
    /// in the background; the user can keep using the view while it works.
    private func reviewAllWithAI() async {
        reviewAll = true
        defer { reviewAll = false }
        let all = state.categoryResults.flatMap(\.items)
        let verdicts = await state.explainBatch(items: all)
        var map: [UUID: BatchVerdict] = [:]
        for v in verdicts { map[v.id] = v }
        batchVerdicts = map
    }
}

// MARK: - Biggest directories explorer

struct DirectoryExplorerView: View {
    @Environment(AppState.self) private var state
    @State private var root = FileManager.default.homeDirectoryForCurrentUser
    @State private var items: [ScanItem] = []
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var sheetPlan: DeletionPlan?
    @State private var renderAsMap = false
    /// AI explanation for the currently-selected row, shown in a sheet.
    @State private var aiExplanation: ItemExplanation?
    @State private var aiReviewingItem: ScanItem?
    @State private var isReviewingWithAI = false

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            if isScanning {
                ProgressView("Sizing \(root.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView("Nothing here",
                                       systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if renderAsMap {
                TreemapView(items: items) { item in
                    root = item.url
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if items.isEmpty { rescan() } }
        .onChange(of: root) { rescan() }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Trash this item?", plan: plan) { _ in
                rescan()
            }
        }
        // Gate on `isReviewingWithAI`, NOT `aiExplanation != nil`. Two bugs to
        // avoid: (1) gating on the explanation hides the sheet until the
        // response lands, so a slow/failed call shows nothing at all — the
        // sheet must open immediately to show the "Asking the AI…" spinner.
        // (2) `isReviewingWithAI` is the *presentation* binding, so it must
        // stay true after the verdict lands; clearing it on completion dismisses
        // the sheet the instant the answer arrives and the user never sees it.
        // The sheet closes only when the user taps Done, which fires `set` and
        // clears all three state vars. See `reviewWithAI` above.
        .sheet(isPresented: Binding(
            get: { isReviewingWithAI },
            set: { if !$0 { aiExplanation = nil; aiReviewingItem = nil; isReviewingWithAI = false } }
        )) {
            AIReviewSheet(item: aiReviewingItem, explanation: aiExplanation)
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            let components = root.pathComponents
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2) }
                Button(component == "/" ? "Mac" : component) {
                    root = URL(fileURLWithPath: components[0...index].joined(separator: "/")
                        .replacingOccurrences(of: "//", with: "/"))
                }
                .buttonStyle(.plain)
                .fontWeight(index == components.count - 1 ? .bold : .regular)
            }
            Spacer()
            Picker("", selection: $renderAsMap) {
                Label("List", systemImage: "list.bullet").tag(false)
                Label("Map", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            Button {
                rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var list: some View {
        List(items) { item in
            HStack {
                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                Text(item.url.lastPathComponent).lineLimit(1)
                Spacer()
                SizeBar(fraction: fraction(of: item))
                Text(item.sizeBytes.formattedBytes)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
                if item.isDirectory {
                    Button {
                        root = item.url
                    } label: {
                        Image(systemName: "chevron.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Drill in")
                }
            }
            .contextMenu {
                Button("Show in Finder") { showInFinder(item.url) }
                // AI review for any disk-browsing file — asks the configured
                // advisor for a safe/review/keep verdict + one-line reason,
                // same path as the category-view "Review with AI" button.
                Button {
                    reviewWithAI(item)
                } label: {
                    Label("Review with AI", systemImage: "sparkles")
                }
                .disabled(state.advisor == nil)
                Button("Trash…", role: .destructive) {
                    sheetPlan = DeletionPlan(items: [item])
                }
            }
        }
    }

    /// Asks the configured advisor to explain a disk-browser item and shows
    /// the verdict in a sheet. Mirrors the category-view AI review flow but
    /// for arbitrary browsed files (not just scanned category items). No-op
    /// when no AI provider is configured.
    private func reviewWithAI(_ item: ScanItem) {
        guard state.advisor != nil else { return }
        aiReviewingItem = item
        aiExplanation = nil
        isReviewingWithAI = true
        Task {
            let explanation = await state.explain(item: item)
            await MainActor.run {
                // Fill in the verdict, but do NOT clear `isReviewingWithAI` —
                // it is the sheet's presentation binding (see the `.sheet`
                // above). Clearing it here would dismiss the sheet the instant
                // the verdict lands, so the user never sees the answer (the
                // "still doesn't work" bug). The sheet's spinner→verdict
                // switch is driven by `explanation == nil` inside
                // `AIReviewSheet`, not by this flag. The sheet closes only when
                // the user taps Done, which fires the binding's `set` and
                // clears all three state vars. `state.explain` always returns a
                // non-nil ItemExplanation (error message on failure), so the
                // spinner can never get stuck.
                aiExplanation = explanation
            }
        }
    }

    private func fraction(of item: ScanItem) -> Double {
        guard let max = items.first?.sizeBytes, max > 0 else { return 0 }
        return Double(item.sizeBytes) / Double(max)
    }

    private func rescan() {
        scanTask?.cancel()
        isScanning = true
        let target = root
        scanTask = Task {
            let result = await DiskScanner.topLevelScan(root: target)
            if !Task.isCancelled {
                items = result
                isScanning = false
            }
        }
    }
}

extension DeletionPlan: Identifiable {
    public var id: String { candidates.map(\.url.path).joined(separator: "|") }
}

/// Sheet showing an AI verdict + one-line reason for a disk-browser file.
/// Shown while the advisor is thinking (spinner) and once the explanation
/// lands. Mirrors the inline verdict the category view shows, but as a
/// standalone sheet for the explorer's ad-hoc review.
private struct AIReviewSheet: View {
    let item: ScanItem?
    let explanation: ItemExplanation?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("AI review").font(.headline)
                Spacer()
            }
            if let item {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent).font(.callout).lineLimit(1)
                    Text(item.url.path).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            Divider()
            if let explanation {
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    if let verdict = explanation.verdict {
                        Image(systemName: verdict.icon)
                            .foregroundStyle(verdict == .safe ? Theme.Status.good : (verdict == .keep ? Theme.Status.blocked : .orange))
                    }
                    Text(explanation.summary).font(.callout)
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking the AI…").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420, height: 200)
    }
}

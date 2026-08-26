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
    @State private var root = FileManager.default.homeDirectoryForCurrentUser
    @State private var items: [ScanItem] = []
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var sheetPlan: DeletionPlan?
    @State private var renderAsMap = false

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
            } else {
                list
            }
        }
        .onAppear { if items.isEmpty { rescan() } }
        .onChange(of: root) { rescan() }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Trash this item?", plan: plan) { _ in
                rescan()
            }
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
                Button("Trash…", role: .destructive) {
                    sheetPlan = DeletionPlan(items: [item])
                }
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

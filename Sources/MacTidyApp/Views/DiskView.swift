import SwiftUI
import CoreKit
import QuickLookUI

struct DirectoryExplorerView: View {
    @Environment(AppState.self) private var state
    @State private var root = FileManager.default.homeDirectoryForCurrentUser
    @State private var items: [ScanItem] = []
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var sizeCache = DiskMapSizeCache()
    @State private var sheetPlan: DeletionPlan?
    /// Why the safety policy would refuse an item, by item: shown as a lock
    /// instead of offering a Trash that can only fail.
    @State private var refusals: [UUID: String] = [:]
    @State private var renderAsMap = false
    @State private var selectedItem: ScanItem?
    @State private var itemCount: Int?
    @State private var counts: [UUID: Int] = [:]
    @State private var history: [URL] = []
    @State private var sortBy = DiskMapSort.size
    @State private var selection: [UUID: ScanItem] = [:]
    @State private var searchText = ""
    @State private var searchItems: [ScanItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var typeFilter = DiskMapType.all
    @State private var sizeFilter = DiskMapSize.any
    @State private var ageFilter = DiskMapAge.any
    /// AI explanation for the currently-selected row, shown in a sheet.
    @State private var aiExplanation: ItemExplanation?
    @State private var aiReviewingItem: ScanItem?
    @State private var isReviewingWithAI = false
    /// "Why is this big?": the folder asked about, what was measured, and the
    /// AI's answer when a provider is set up.
    @State private var whyBigItem: ScanItem?
    @State private var whyBigProfile: FolderProfile?
    @State private var whyBigAnswer: ItemExplanation?
    @State private var isAskingWhyBig = false
    @State private var whyBigTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                PageHeader(title: "Disk Map", subtitle: "What takes up space, folder by folder. Double-click a folder to open it.") {
                    Picker("", selection: $renderAsMap) {
                        Image(systemName: "list.bullet").tag(false)
                        Image(systemName: "square.grid.2x2").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button { rescan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                breadcrumb
                HStack {
                    TextField("Search within this folder", text: $searchText).textFieldStyle(.roundedBorder)
                    Picker("Type", selection: $typeFilter) { ForEach(DiskMapType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 110)
                    Picker("Size", selection: $sizeFilter) { ForEach(DiskMapSize.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 125)
                    Picker("Age", selection: $ageFilter) { ForEach(DiskMapAge.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 125)
                }
                HStack {
                    if isScanning { ProgressView().controlSize(.small); Text("Measuring…").font(Theme.Font.caption).foregroundStyle(.secondary) }
                    if !selection.isEmpty {
                        Text("\(selection.count) selected").font(Theme.Font.caption)
                        Button("Clear All") { selection.removeAll() }
                        Button("Review Cleanup…") { sheetPlan = DeletionPlan(items: Array(selection.values)) }
                    }
                    Spacer()
                    Picker("Sort", selection: $sortBy) {
                        ForEach(DiskMapSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 160)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.md)
            Group {
                if isScanning && items.isEmpty {
                    ProgressView("Measuring \(root.lastPathComponent)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sortedItems.isEmpty {
                    EmptyStateView(symbol: "folder", title: searchText.isEmpty ? "No matching items" : "No search results yet")
                        .frame(maxHeight: .infinity)
                } else if renderAsMap {
                    TreemapView(items: sortedItems) { item in selectedItem = item; if item.isDirectory { navigate(to: item.url) } }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                        .padding(.horizontal, Theme.gutter)
                        .padding(.bottom, Theme.Spacing.xl)
                } else {
                    ScrollView { list.padding(.horizontal, Theme.gutter).padding(.bottom, Theme.Spacing.xl) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let selectedItem { inspector(selectedItem) }
        }
        .background(Theme.canvas)
        .onAppear { if !CommandLine.arguments.contains("--snapshot") { rescan(); startSearch() } }
        .onDisappear { scanTask?.cancel(); searchTask?.cancel(); whyBigTask?.cancel() }
        .onChange(of: root) { rescan(); startSearch() }
        .onChange(of: searchText) { startSearch() }
        .onChange(of: selectedItem) { _, item in
            itemCount = nil
            guard let item, item.isDirectory else { return }
            Task {
                let count = await Task.detached { DiskMapDetails.childCount(at: item.url) }.value
                if selectedItem?.id == item.id { itemCount = count }
            }
        }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Review cleanup", plan: plan) { _ in
                selection.removeAll()
                sizeCache.invalidate()
                rescan()
                startSearch()
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
        .sheet(item: $whyBigItem, onDismiss: { whyBigTask?.cancel() }) { item in
            WhyBigSheet(folder: item.url, profile: whyBigProfile, answer: whyBigAnswer,
                        isAsking: isAskingWhyBig, aiAvailable: state.advisor != nil,
                        sendsNames: state.aiConfig.sendFilePaths)
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button { if let previous = history.popLast() { root = previous } } label: { Image(systemName: "chevron.left") }.disabled(history.isEmpty).help("Back")
            Button { navigate(to: root.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }.disabled(root.path == "/").help("Up")
            let components = root.pathComponents
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Button(component == "/" ? "Macintosh HD" : component) {
                    navigate(to: URL(fileURLWithPath: components[0...index].joined(separator: "/")
                        .replacingOccurrences(of: "//", with: "/")))
                }
                .buttonStyle(.plain)
                .font(Theme.Font.body.weight(index == components.count - 1 ? .semibold : .regular))
                .foregroundStyle(index == components.count - 1 ? Color.primary : Color.secondary)
            }
            Spacer()
            if !items.isEmpty {
                Text(items.reduce(0) { $0 + $1.sizeBytes }.formattedBytes)
                    .font(Theme.Font.body.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(sortedItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider(inset: 50) }
                explorerRow(item)
            }
        }
        .cardStyle(padded: false)
    }

    private func explorerRow(_ item: ScanItem) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            if eligible(item) {
                Toggle("Select \(item.url.lastPathComponent)", isOn: Binding(
                    get: { selection[item.id] != nil },
                    set: { selected in setSelected(item, selected) }
                )).labelsHidden().toggleStyle(.checkbox)
            } else { Image(systemName: "lock.fill").foregroundStyle(.tertiary).frame(width: 16) }
            Button { selectedItem = item } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(nsImage: FileIcon.image(for: item.url))
                    .resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(item.url.lastPathComponent).font(Theme.Font.bodyStrong).lineLimit(1)
                        if let refusal = refusals[item.id] {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .help(refusal)
                        }
                    }
                    if let note = note(for: item) {
                        Text(note).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Spacing.lg)
                Meter(fraction: fraction(of: item)).frame(width: 140)
                Text(item.sizeBytes.formattedBytes)
                    .font(Theme.Font.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(item.isDirectory ? 1 : 0)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm + 2)
        }
        .buttonStyle(RowButtonStyle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { if item.isDirectory { navigate(to: item.url) } })
        }
        .contextMenu {
                if item.isDirectory { Button("Open Folder") { navigate(to: item.url) } }
                Button("Show in Finder") { showInFinder(item.url) }
                Button("Quick Look") { DiskMapQuickLook.show(item.url) }
                if AppSupportRules.isUnrecognized(item) {
                    Button {
                        askWhyBig(item)
                    } label: {
                        Label("Why Is This Big?", systemImage: "questionmark.circle")
                    }
                }
                // AI review for any disk-browsing file — asks the configured
                // advisor for a safe/review/keep verdict + one-line reason,
                // same path as the category-view "Review with AI" button.
                Button {
                    reviewWithAI(item)
                } label: {
                    Label("Review with AI", systemImage: "sparkles")
                }
                .disabled(state.advisor == nil)
                if !eligible(item) {
                    Button("Protected or managed elsewhere") {}.disabled(true)
                } else {
                    Button("Trash…", role: .destructive) {
                        sheetPlan = DeletionPlan(items: [item])
                    }
                }
            }
    }

    /// What MacTidy knows about the item: the protection, or for folders in
    /// Application Support, what they are.
    private func note(for item: ScanItem) -> String? {
        if let refusal = refusals[item.id] { return refusal }
        if let rule = HandledElsewhere.rule(covering: item.url) {
            return "\(rule.label) · manage in \(rule.managedIn)"
        }
        guard let insight = AppSupportRules.insight(for: item.url) else { return nil }
        let verdict = switch insight.risk {
        case .safe: "safe to trash"
        case .caution: "check before trashing"
        case .danger: "can't be rebuilt"
        }
        return "\(insight.label) · \(verdict)"
    }

    /// The policy's verdict for each item, in plain words, for the ones it
    /// would refuse.
    nonisolated private static func refusals(for items: [ScanItem], extraRoots: [URL]) -> [UUID: String] {
        let policy = SafePathPolicy(extraAllowedRoots: extraRoots)
        var refusals: [UUID: String] = [:]
        for item in items {
            guard case .failure(let violation) = policy.classify(item.url) else { continue }
            refusals[item.id] = switch violation {
            case .protectedAppData: "macOS, iCloud or a browser login keeps data here"
            case .credentialPath: "holds keys, logins or app settings"
            case .deniedSystemPath: "part of macOS"
            case .criticalDirectory: "a system folder; trash what's inside instead"
            case .protectedUserFolder: "your personal files"
            case .outsideAllowedRoots: "outside the folders MacTidy cleans"
            }
        }
        return refusals
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

    /// Measures the folder, then asks the AI if one is set up. With none, the
    /// measurements are the answer.
    private func askWhyBig(_ item: ScanItem) {
        whyBigTask?.cancel()
        whyBigProfile = nil
        whyBigAnswer = nil
        isAskingWhyBig = false
        whyBigItem = item
        whyBigTask = Task {
            let profile = await FolderProfile.read(item.url)
            guard !Task.isCancelled else { return }
            whyBigProfile = profile
            guard state.advisor != nil else { return }
            isAskingWhyBig = true
            let answer = await state.explainFolder(profile)
            guard !Task.isCancelled else { return }
            whyBigAnswer = answer
            isAskingWhyBig = false
        }
    }

    private func fraction(of item: ScanItem) -> Double {
        guard let max = items.map(\.sizeBytes).max(), max > 0 else { return 0 }
        return Double(item.sizeBytes) / Double(max)
    }

    private var sortedItems: [ScanItem] {
        let base = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? items : searchItems
        let filter = DiskMapFilter(kind: typeFilter.kind, minimumBytes: sizeFilter.bytes, modifiedBefore: ageFilter.before)
        return base.filter { filter.matches($0) }.sorted { a, b in
            switch sortBy {
            case .size: return a.sizeBytes > b.sizeBytes
            case .name: return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            case .date: return (a.lastModified ?? .distantPast) > (b.lastModified ?? .distantPast)
            case .count: return (counts[a.id] ?? -1) > (counts[b.id] ?? -1)
            }
        }
    }

    private func eligible(_ item: ScanItem) -> Bool {
        DiskMapSelection.isEligible(item, extraRoots: state.extraAllowedRoots)
    }

    private func setSelected(_ item: ScanItem, _ selected: Bool) {
        if !selected { selection.removeValue(forKey: item.id); return }
        guard eligible(item) else { return }
        let next = DiskMapSelection.adding(item, to: Array(selection.values))
        selection = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
    }

    private func startSearch() {
        searchTask?.cancel(); searchItems = []
        let target = root, query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchTask = Task {
            for await item in DiskMapSearch.search(root: target, name: query, cache: sizeCache) {
                guard !Task.isCancelled else { return }
                searchItems.append(item)
                if item.isDirectory {
                    Task {
                        let count = await Task.detached { DiskMapDetails.childCount(at: item.url) }.value
                        if root == target, let count { counts[item.id] = count }
                    }
                } else { counts[item.id] = 0 }
            }
        }
    }

    private func navigate(to url: URL) {
        guard url != root else { return }
        history.append(root); root = url
    }

    private func inspector(_ item: ScanItem) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(nsImage: FileIcon.image(for: item.url)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).font(Theme.Font.bodyStrong)
                Text(item.url.path).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("\(item.sizeBytes.formattedBytes) · \(item.lastModified?.formatted(date: .abbreviated, time: .omitted) ?? "Date unavailable")" + (item.isDirectory ? " · \(itemCount.map(String.init) ?? "…") items" : ""))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                if let note = note(for: item) { Text(note).font(Theme.Font.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if item.isDirectory { Button("Open") { navigate(to: item.url) }; Button("Why Is This Big?") { askWhyBig(item) } }
            Button("Reveal") { showInFinder(item.url) }
            Button("Quick Look") { DiskMapQuickLook.show(item.url) }
            Button { selectedItem = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }.padding(Theme.Spacing.md).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface)
    }

    private func rescan() {
        scanTask?.cancel()
        isScanning = true
        let target = root
        let extraRoots = state.extraAllowedRoots
        items = []
        refusals = [:]
        counts = [:]
        scanTask = Task {
            for await item in DiskMapScanner.scan(root: target, cache: sizeCache) {
                guard !Task.isCancelled else { return }
                items.append(item)
                if item.isDirectory {
                    Task {
                        let count = await Task.detached { DiskMapDetails.childCount(at: item.url) }.value
                        if root == target, let count { counts[item.id] = count }
                    }
                } else { counts[item.id] = 0 }
                items.sort { $0.sizeBytes > $1.sizeBytes }
                refusals.merge(Self.refusals(for: [item], extraRoots: extraRoots)) { _, new in new }
            }
            if !Task.isCancelled { isScanning = false }
        }
    }
}

extension DeletionPlan: Identifiable {
    /// The candidates' ids are fresh per plan, so the first one identifies
    /// it. (Joining every path rebuilt a huge string on each view update.)
    public var id: UUID? { candidates.first?.id }
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

private enum DiskMapSort: String, CaseIterable { case size = "Size", name = "Name", date = "Date", count = "Count" }

private enum DiskMapType: String, CaseIterable {
    case all = "All types", files = "Files", folders = "Folders"
    var kind: DiskMapFilter.Kind { switch self { case .all: .all; case .files: .files; case .folders: .folders } }
}
private enum DiskMapSize: String, CaseIterable {
    case any = "Any size", mb100 = "> 100 MB", gb1 = "> 1 GB"
    var bytes: Int64 { switch self { case .any: 0; case .mb100: 100_000_000; case .gb1: 1_000_000_000 } }
}
private enum DiskMapAge: String, CaseIterable {
    case any = "Any age", month = "Over 30 days", year = "Over a year"
    var before: Date? { switch self { case .any: nil; case .month: Date().addingTimeInterval(-30 * 86400); case .year: Date().addingTimeInterval(-365 * 86400) } }
}
private final class DiskMapQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = DiskMapQuickLook()
    private var url: URL?
    static func show(_ url: URL) {
        shared.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = shared
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}

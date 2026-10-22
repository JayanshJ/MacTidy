import SwiftUI
import CoreKit

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
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                PageHeader(title: "Disk Map", subtitle: "What takes up space, folder by folder. Click a folder to go inside.") {
                    Picker("", selection: $renderAsMap) {
                        Image(systemName: "list.bullet").tag(false)
                        Image(systemName: "square.grid.2x2").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button { rescan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(isScanning)
                }
                breadcrumb
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.md)
            Group {
                if isScanning {
                    ProgressView("Measuring \(root.lastPathComponent)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    EmptyStateView(symbol: "folder", title: "Empty folder")
                        .frame(maxHeight: .infinity)
                } else if renderAsMap {
                    TreemapView(items: items) { item in root = item.url }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                        .padding(.horizontal, Theme.gutter)
                        .padding(.bottom, Theme.Spacing.xl)
                } else {
                    ScrollView { list.padding(.horizontal, Theme.gutter).padding(.bottom, Theme.Spacing.xl) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
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
        HStack(spacing: 6) {
            let components = root.pathComponents
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Button(component == "/" ? "Macintosh HD" : component) {
                    root = URL(fileURLWithPath: components[0...index].joined(separator: "/")
                        .replacingOccurrences(of: "//", with: "/"))
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
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider(inset: 50) }
                explorerRow(item)
            }
        }
        .cardStyle(padded: false)
    }

    private func explorerRow(_ item: ScanItem) -> some View {
        Button {
            if item.isDirectory { root = item.url } else { showInFinder(item.url) }
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable().frame(width: 22, height: 22)
                Text(item.url.lastPathComponent).font(Theme.Font.bodyStrong).lineLimit(1)
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

import SwiftUI
import CoreKit

func showInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// Horizontal bar visualizing an item's share of the largest item in a list.
/// Defaults to a 90pt fixed width for inline row use; pass `fillsWidth: true`
/// to let it stretch to its container (used in category cards).
struct SizeBar: View {
    let fraction: Double
    var fillsWidth: Bool = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // Use a separator-level fill so the track is visible in both
                // light and dark mode (.quaternary washes out in light mode).
                Capsule().fill(.separator.opacity(0.5))
                Capsule()
                    .fill(.tint)
                    .frame(width: max(2, proxy.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
        .frame(maxWidth: fillsWidth ? .infinity : 90)
    }
}
/// Standard row for a scanned item: checkbox, name, context, size,
/// Show in Finder.
struct ScanItemRow: View {
    @Environment(AppState.self) private var state
    let item: ScanItem
    @Binding var selection: Set<UUID>
    /// A batch verdict injected from the parent (category-level "Review with
    /// AI"). Renders inline like the per-row `explain()` result so the UI has
    /// one consistent verdict surface, not two.
    var batchVerdict: BatchVerdict?
    @State private var explanation: ItemExplanation?
    @State private var isExplaining = false
    @State private var showSafetyNote = false

    /// The verdict to show: a batch verdict takes precedence over the row's
    /// own one-shot `explain()` result, since batch is the more deliberate pass.
    private var displayedVerdict: (verdict: ItemExplanation.Verdict?, summary: String)? {
        if let batchVerdict { return (batchVerdict.verdict, batchVerdict.summary) }
        if let explanation { return (explanation.verdict, explanation.summary) }
        return nil
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Toggle("", isOn: Binding(
                get: { selection.contains(item.id) },
                set: { isOn in
                    if isOn { selection.insert(item.id) } else { selection.remove(item.id) }
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let displayed = displayedVerdict {
                    HStack(spacing: 4) {
                        if let verdict = displayed.verdict {
                            Image(systemName: verdict.icon)
                                .foregroundStyle(verdictColor(verdict))
                        }
                        if !displayed.summary.isEmpty {
                            Text(displayed.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            Text(item.sizeBytes.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                showInFinder(item.url)
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .contextMenu {
            Button("Show in Finder") { showInFinder(item.url) }
            if item.category != nil {
                Button("Why is this suggested?") { showSafetyNote = true }
            }
            Button {
                Task { await explain() }
            } label: {
                if isExplaining {
                    Text("Explaining…")
                } else {
                    Label("Explain with AI", systemImage: "sparkles")
                }
            }
        }
        .alert(
            item.url.lastPathComponent,
            isPresented: $showSafetyNote
        ) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text(item.category?.explanation ?? "")
        }
    }

    private func explain() async {
        isExplaining = true
        let result = await state.explain(item: item)
        explanation = result
        isExplaining = false
    }

    private func verdictColor(_ v: ItemExplanation.Verdict) -> Color {
        switch v {
        case .safe: Theme.Status.good
        case .review: .orange
        case .keep: .red
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let detail = item.detail { parts.append("in \(detail)") }
        if let modified = item.lastModified {
            parts.append("modified \(modified.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Footer bar with the running selection total and the trash button.
struct SelectionFooter: View {
    let selectedCount: Int
    let selectedBytes: Int64
    let buttonTitle: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            if selectedCount > 0 {
                Text("\(selectedCount) item\(selectedCount == 1 ? "" : "s") selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(selectedBytes.formattedBytes)
                    .font(.callout.bold().monospacedDigit())
                    .foregroundStyle(Theme.accent)
            } else {
                Text("Nothing selected")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled || selectedCount == 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(.bar)
    }
}

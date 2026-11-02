import SwiftUI
import CoreKit

func showInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// Finder icons, cached by path. `NSWorkspace.icon(forFile:)` asks Launch
/// Services each call, and list rows re-run their body on every checkbox
/// click, so uncached lookups made big lists stutter.
enum FileIcon {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2000
        return cache
    }()

    static func image(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

/// Horizontal bar visualizing an item's share of the largest item in a list.
/// Defaults to a 90pt fixed width for inline row use; pass `fillsWidth: true`
/// to let it stretch to its container (used in category cards).
struct SizeBar: View {
    let fraction: Double
    var fillsWidth: Bool = false

    var body: some View {
        Meter(fraction: fraction)
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
        // Application Support items say what they are; their folder names
        // ("Cache", "2.1.308") mean little on their own.
        // Handled elsewhere: shown, never selectable, so never trashable here.
        let elsewhere = HandledElsewhere.rule(for: item)
        let insight = elsewhere == nil && (item.category == .appSupport || item.finding != nil)
            ? AppSupportRules.insight(for: item) : nil
        HStack(spacing: Theme.Spacing.md) {
            if elsewhere == nil {
                Toggle("", isOn: Binding(
                    get: { selection.contains(item.id) },
                    set: { isOn in
                        if isOn { selection.insert(item.id) } else { selection.remove(item.id) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }

            Image(nsImage: FileIcon.image(for: item.url))
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(insight?.label ?? elsewhere?.title(for: item) ?? item.url.lastPathComponent)
                        .font(Theme.Font.bodyStrong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.risk != .safe {
                        Badge(text: item.risk.label,
                              tint: item.risk == .danger ? Theme.Status.blocked : Theme.Status.caution)
                            .help("Never preselected. \(insight == nil ? item.detail ?? "" : "")")
                    }
                }
                if let subtitle = subtitle(insight, elsewhere) {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let insight {
                    Text(insight.explanation)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
            Spacer(minLength: Theme.Spacing.lg)
            Text(item.sizeBytes.formattedBytes)
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                showInFinder(item.url)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contextMenu {
            Button("Show in Finder") { showInFinder(item.url) }
            Button("Never Suggest This") { state.ignore(item.url) }
            if item.category != nil {
                Button("Why is this suggested?") { showSafetyNote = true }
            }
            if elsewhere == nil {
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
        }
        .alert(
            item.url.lastPathComponent,
            isPresented: $showSafetyNote
        ) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text(insight?.explanation ?? item.category?.explanation ?? "")
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

    private func subtitle(_ insight: AppSupportInsight?, _ elsewhere: ElsewhereRule?) -> String? {
        var parts: [String] = []
        if insight != nil, let path = AppSupportRules.displayPath(of: item.url) {
            parts.append(path)
        } else if elsewhere != nil {
            parts.append((item.url.path as NSString).abbreviatingWithTildeInPath)
        } else if let detail = item.detail {
            parts.append(item.finding == nil ? "in \(detail)" : detail)
        }
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
        HStack(spacing: Theme.Spacing.sm) {
            if selectedCount > 0 {
                Text(selectedBytes.formattedBytes)
                    .font(Theme.Font.figure)
                    .contentTransition(.numericText())
                Text("in \(selectedCount) item\(selectedCount == 1 ? "" : "s")")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select items to clean")
                    .font(Theme.Font.body)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled || selectedCount == 0)
        }
        .animation(Theme.ease, value: selectedBytes)
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, Theme.Spacing.md)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

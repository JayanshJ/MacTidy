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
                Capsule().fill(.quaternary)
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
    let item: ScanItem
    @Binding var selection: Set<UUID>

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

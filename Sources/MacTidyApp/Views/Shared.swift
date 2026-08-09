import SwiftUI
import CoreKit

func showInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// Horizontal bar visualizing an item's share of the largest item in a list.
struct SizeBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(2, proxy.size.width * fraction))
            }
        }
        .frame(width: 90, height: 6)
    }
}

/// Standard row for a scanned item: checkbox, name, context, size,
/// Show in Finder.
struct ScanItemRow: View {
    let item: ScanItem
    @Binding var selection: Set<UUID>

    var body: some View {
        HStack {
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
            Text("\(selectedCount) item\(selectedCount == 1 ? "" : "s") selected · \(selectedBytes.formattedBytes)")
                .foregroundStyle(.secondary)
            Spacer()
            Button(buttonTitle, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled || selectedCount == 0)
        }
        .padding()
        .background(.bar)
    }
}

import SwiftUI
import CoreKit

/// The menu bar popover: an at-a-glance quick-check summary plus one-click
/// access to the app. Lives in a MenuBarExtra so MacTidy stays present even
/// with the main window closed.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            Divider()
            summary
            if !state.monitor.latestResults.isEmpty {
                Divider()
                ForEach(state.monitor.latestResults.prefix(4)) { result in
                    HStack {
                        Image(systemName: "tray.full")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(result.category.displayName)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Text(result.totalBytes.formattedBytes)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            actions
        }
        .padding(Theme.Spacing.md)
        .frame(width: 280)
        .task { state.monitor.start() }
    }

    private var header: some View {
        HStack {
            Text("MacTidy")
                .font(.headline)
            Spacer()
            if let lastCheckedText {
                Text(lastCheckedText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var lastCheckedText: String? {
        guard let checked = state.monitor.lastChecked else { return nil }
        let style = Date.RelativeFormatStyle(presentation: .named, capitalizationContext: .beginningOfSentence)
        return checked.formatted(style) + (state.monitor.isChecking ? " · checking…" : "")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.monitor.reclaimableBytes.formattedBytes)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(state.monitor.reclaimableBytes > 0 ? Theme.accent : .secondary)
            Text("reclaimable (quick check)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open MacTidy", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                Task { await state.monitor.checkNow() }
            } label: {
                if state.monitor.isChecking {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking…") }
                } else {
                    Label("Quick check now", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.monitor.isChecking || !state.fdaGranted)
            .frame(maxWidth: .infinity)
        }
    }
}

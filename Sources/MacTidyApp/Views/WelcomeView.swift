import SwiftUI
import CoreKit

/// First run only: one sentence, one action. Later launches open straight
/// into the app with the last scan restored.
struct WelcomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: Theme.Spacing.lg) {
                appIcon
                VStack(spacing: Theme.Spacing.sm) {
                    Text("MacTidy")
                        .font(.system(size: 34, weight: .semibold))
                    Text("See what's safe to remove, move it to the Trash,\nand put it back if you change your mind.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                Button {
                    Task { await state.startFlow() }
                } label: {
                    Text("Scan This Mac")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, Theme.Spacing.md)
            }
            Spacer()
            HStack(spacing: Theme.Spacing.xxl) {
                fact("arrow.uturn.backward", "Everything goes to the Trash")
                fact("lock", "System folders and credentials are off-limits")
                fact("eye", "Nothing is selected without a reason")
            }
            .padding(.bottom, Theme.Spacing.xl)
            Text("Version \(AppVersion.short)")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appIcon: some View {
        Group {
            if let image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: image).resizable().interpolation(.high)
            }
        }
        .frame(width: 104, height: 104)
    }
}

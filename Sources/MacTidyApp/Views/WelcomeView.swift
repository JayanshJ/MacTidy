import SwiftUI
import CoreKit

/// The launch screen. A polished hero: the real app icon, a tagline, three
/// feature highlights, and one clear call to action. The honest subtitle
/// tells the user up front that this is Move-to-Trash, reversible, and that
/// the first pass is a dry preview.
struct WelcomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero: real app icon + name + tagline.
            VStack(spacing: Theme.Spacing.md) {
                appIcon
                Text("MacTidy")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Reclaim disk space, guided.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Feature highlights.
            HStack(spacing: Theme.Spacing.xl) {
                feature(icon: "arrow.2.squarepath.circle",
                        title: "Move to Trash",
                        text: "Everything is reversible. Restore from Trash to undo.")
                feature(icon: "shield.lefthalf.filled",
                        title: "Safe by default",
                        text: "A hard denylist protects /System, Documents, Photos, and more.")
                feature(icon: "eye.circle",
                        title: "Dry-run preview",
                        text: "See what would be cleaned before anything is touched.")
            }
            .frame(maxWidth: 720)
            .padding(.bottom, Theme.Spacing.xl)

            // Honest subtitle + the single primary action.
            VStack(spacing: Theme.Spacing.sm) {
                Text("MacTidy scans your Mac, then shows the biggest, safest things to clean — all at once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button {
                    Task { await state.startFlow() }
                } label: {
                    Label("Start Cleanup", systemImage: "arrow.right.circle.fill")
                        .font(.title3.bold())
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
        .background(.linearGradient(
            colors: [Theme.accent.opacity(0.10), .clear],
            startPoint: .top, endPoint: .bottom
        ))
        .overlay(alignment: .topTrailing) { versionBadge }
    }

    /// The real app icon, rendered from the bundle's AppIcon asset so the
    /// welcome hero matches the dock icon exactly.
    private var appIcon: some View {
        Group {
            if let nsImage = NSImage(named: "AppIcon") ?? bundledAppIcon {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
            } else {
                // Fallback to the disk-ring glyph if the bundle icon is absent
                // (e.g. running as a bare SwiftPM binary without a bundle).
                Image(systemName: "circle.dashed")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }

    private var versionBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("v\(AppVersion.short)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text("for macOS 14+")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.top, Theme.Spacing.md)
        .padding(.trailing, Theme.Spacing.md)
    }

    private func feature(icon: String, title: String, text: String) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.callout.bold())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
        }
    }

    /// Reads the app icon from the running bundle's Resources, used when the
    /// SwiftUI `AppIcon` asset isn't resolvable (bare SwiftPM binary path).
    private var bundledAppIcon: NSImage? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: "AppIcon", withExtension: "icns")
            ?? bundle.url(forResource: "AppIcon", withExtension: "png")
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Reads the marketing version + build number from the main bundle's
/// Info.plist so the welcome screen and Settings show a consistent version.
public enum AppVersion {
    public static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    public static var full: String { "\(short) (\(build))" }
}
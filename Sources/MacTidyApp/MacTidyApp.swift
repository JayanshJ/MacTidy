import SwiftUI
import CoreKit

@main
struct MacTidyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("MacTidy") {
            RootView()
                .environment(state)
                .tint(Theme.accent)
                .frame(minWidth: 940, minHeight: 600)
                .onAppear { delegate.sizeMainWindow() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // Replace the default "New Window" command so the app stays
            // single-window — a cleaner utility-app presence.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About MacTidy") { delegate.showAbout() }
            }
        }
    }
}

/// Run as a bare SwiftPM executable we still want a normal app presence:
/// dock icon, key window, quit on close. Also sizes the main window to a
/// sensible default and surfaces an About panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        sizeMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Sizes the first (main) window to a comfortable default, centered on
    /// the active screen — so the app always opens at a sensible size rather
    /// than whatever SwiftUI's autosave last left.
    func sizeMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.isKeyWindow })
            ?? NSApp.windows.first else { return }
        let w: CGFloat = 1080, h: CGFloat = 720
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - w / 2
            let y = frame.midY - h / 2
            window.setFrame(CGRect(x: x, y: y, width: w, height: h), display: true)
        } else {
            window.setContentSize(NSSize(width: w, height: h))
        }
        window.minSize = NSSize(width: 940, height: 600)
        window.title = "MacTidy"
    }

    /// A minimal About panel showing the app icon, name, version, and
    /// copyright — the standard utility-app "About" box.
    func showAbout() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.contentView = NSHostingView(rootView: AboutPanelView())
        panel.center()
        NSApp.runModal(for: panel)
    }
}

private struct AboutPanelView: View {
    var body: some View {
        VStack(spacing: 10) {
            if let icon = NSImage(named: "AppIcon")
                ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
            }
            Text("MacTidy").font(.title2.bold())
            Text("Version \(AppVersion.full)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Reclaim disk space, guided.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("© 2026 Jayansh Jain")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
    }
}

import SwiftUI
import CoreKit
import UserNotifications

@main
struct MacTidyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("MacTidy", id: "main") {
            RootView()
                .environment(state)
                .tint(Theme.accent)
                .frame(minWidth: 940, minHeight: 600)
                .onAppear {
                    delegate.sizeMainWindow()
                    state.monitor.start()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        // The resident menu bar presence: quick-check summary + open/scan.
        MenuBarExtra("MacTidy", systemImage: "paintbrush") {
            MenuBarPanel()
                .environment(state)
        }
        .menuBarExtraStyle(.window)
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
/// dock icon, key window. Closing the window keeps the app resident in the
/// menu bar (the SpaceMonitor keeps watching); reopening happens via the
/// menu bar panel or a Dock click. Also sizes the main window to a sensible
/// default and surfaces an About panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless scheduled-cleanup launch path: launchd relaunches MacTidy
        // with `--run-scheduled` at the job's fire time. Run any due jobs
        // through the same destructive path as a manual cleanup, then quit
        // — no UI. The app records to TrashLog/CleanupLog like a normal run.
        if CommandLine.arguments.contains(LaunchAgentWriter.runScheduledFlag) {
            runScheduledAndExit()
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        sizeMainWindow()
    }

    /// Runs due scheduled jobs headlessly and quits. Runs as a background
    /// (accessory) app so no dock icon or window appears for the fire. Uses
    /// its own `AppState` — the headless path doesn't touch UI state, it just
    /// scans + trashes through the same destructive path and records to the
    /// shared TrashLog/CleanupLog (which are singletons).
    private func runScheduledAndExit() {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            let headlessState = AppState()
            await headlessState.runScheduledIfDue()
            // Quit once the run completes. A nil result (nothing due) still
            // quits — the agent fired, found nothing, and should exit cleanly
            // rather than lingering.
            NSApp.terminate(nil)
        }
    }

    /// Stay alive with the window closed — the menu bar icon and the space
    /// monitor keep working. Quit is Cmd-Q or the panel's standard menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock-click reopen: bring the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    private let notificationDelegate = NotificationDelegate()

    /// Brings the main window to front. Closed SwiftUI windows stay alive
    /// (hidden) in `NSApp.windows`, so a lookup by title + makeKeyAndOrderFront
    /// reshows them; otherwise activating the app is all we can do.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "MacTidy" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
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

/// Shows pile-up alerts as banners even when MacTidy is frontmost, and opens
/// the main window when one is clicked.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.showMainWindow()
        }
    }
}

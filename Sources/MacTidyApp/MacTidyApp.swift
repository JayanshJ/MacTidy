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
        }
    }
}

/// Run as a bare SwiftPM executable we still want a normal app presence:
/// dock icon, key window, quit on close.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

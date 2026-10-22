import SwiftUI
import CoreKit

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if !state.fdaGranted && !state.fdaSkipped {
                FDAOnboardingView()
            } else if state.flowPhase == .welcome && state.categoryResults.isEmpty {
                WelcomeView()
            } else {
                MainShell()
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .animation(Theme.ease, value: state.flowPhase)
        // Access often arrives while the app is open (onboarding polls); run
        // the first scan then instead of leaving an empty dashboard.
        .onChange(of: state.fdaGranted) { _, granted in
            if granted && state.autoScanOnLaunch && state.categoryResults.isEmpty {
                Task { await state.rescanCategories() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshFDA()
            // The user may have emptied the Trash in Finder while we were
            // inactive — reconcile the Recently Trashed list and the Trash
            // size nudge with the actual Trash.
            state.refreshLogs()
        }
        .task {
            if SnapshotHarness.isActive {
                await SnapshotHarness.run(state: state)
                return
            }
            if state.fdaGranted && state.autoScanOnLaunch && state.categoryResults.isEmpty {
                await state.rescanCategories()
            }
            // Self-update check on launch (gated by a persisted toggle so the
            // user can turn off the network call in Settings). The check only
            // resolves an "available" phase; it never auto-installs.
            if state.updates.checkOnLaunch && state.updates.phase == .idle {
                state.updates.check()
            }
        }
    }
}

import SwiftUI
import CoreKit

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.fdaGranted {
                FlowView()
            } else {
                FDAOnboardingView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshFDA()
        }
        .task {
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

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
        }
    }
}

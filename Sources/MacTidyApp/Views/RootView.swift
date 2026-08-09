import SwiftUI
import CoreKit

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.fdaGranted {
                MainSplitView()
            } else {
                FDAOnboardingView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshFDA()
        }
    }
}

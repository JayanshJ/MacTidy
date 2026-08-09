import SwiftUI
import CoreKit

struct FDAOnboardingView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Full Disk Access needed")
                .font(.title.bold())
            Text("""
            MacTidy scans ~/Library, app data, and caches — locations macOS \
            protects behind Full Disk Access. Without it the scan results \
            would be silently incomplete.

            Grant access in System Settings → Privacy & Security → \
            Full Disk Access, then come back to this window.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460)

            HStack {
                Button("Open System Settings") {
                    FullDiskAccess.openSettingsPane()
                }
                .keyboardShortcut(.defaultAction)
                Button("Check Again") {
                    state.refreshFDA()
                }
            }
            Text("MacTidy never deletes anything without confirmation; deletion always means Move to Trash.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

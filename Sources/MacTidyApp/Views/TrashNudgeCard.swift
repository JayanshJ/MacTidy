import SwiftUI
import CoreKit

/// Overview nudge that surfaces how much space the macOS Trash itself holds.
/// MacTidy moves everything *to* the Trash (reversible) but never empties it —
/// an explicit invariant — so this card closes the reclaim loop by pointing
/// the user to Finder when the Trash is large. Non-destructive: it only opens
/// Finder; it never empties the Trash.
struct TrashNudgeCard: View {
    /// Threshold above which the nudge is worth showing (1 GB). Below this the
    /// Trash isn't meaningfully holding reclaimable space.
    static let threshold: Int64 = 1_073_741_824

    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "trash")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("The Trash is holding \(state.trashBytes.formattedBytes)")
                    .font(Theme.Font.bodyStrong)
                Text("That space only comes back once you empty it. MacTidy never empties the Trash for you.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Trash") { openTrash() }
        }
        .cardStyle()
    }

    /// Opens the Trash in Finder via AppleScript (the reliable way to focus
    /// the Trash window specifically, not just the Downloads folder).
    private func openTrash() {
        _ = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to open trash"])
        // Also bring Finder forward as a fallback if the script didn't focus it.
        _ = Shell.run("/usr/bin/open", ["-a", "Finder"])
    }
}
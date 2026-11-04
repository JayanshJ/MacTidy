import SwiftUI
import CoreKit

/// Trash size and explicitly confirmed manual disposal through Finder.
struct TrashNudgeCard: View {
    /// Threshold above which the nudge is worth showing (1 GB). Below this the
    /// Trash isn't meaningfully holding reclaimable space.
    static let threshold: Int64 = 1_073_741_824

    @Environment(AppState.self) private var state
    @State private var confirming = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "trash")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("The Trash is holding \(state.trashBytes.formattedBytes)")
                    .font(Theme.Font.bodyStrong)
                Text("Space returns after emptying Trash. Permanent removal cannot be undone.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Trash") { openTrash() }
            Button(state.isEmptyingTrash ? "Emptying…" : "Empty Trash…", role: .destructive) { confirming = true }
                .disabled(state.isEmptyingTrash || state.isTrashBusy)
        }
        .cardStyle()
        .confirmationDialog("Permanently empty all Trash?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Empty all Trash permanently", role: .destructive) { Task { await state.emptyTrash() } }
                .disabled(state.isEmptyingTrash || state.isTrashBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Finder will permanently delete all Trash items, including files from other apps and connected disks. MacTidy cannot restore them afterward.")
        }
    }

    /// Opens the Trash in Finder via AppleScript (the reliable way to focus
    /// the Trash window specifically, not just the Downloads folder).
    private func openTrash() {
        _ = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to open trash"])
        // Also bring Finder forward as a fallback if the script didn't focus it.
        _ = Shell.run("/usr/bin/open", ["-a", "Finder"])
    }
}
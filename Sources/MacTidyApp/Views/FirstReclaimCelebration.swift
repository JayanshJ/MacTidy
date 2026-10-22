import SwiftUI
import CoreKit

/// One-time celebration shown after the user's first real cleanup that frees
/// space. Sits next to `UndoToast` in `FlowView`. Auto-dismisses after a few
/// seconds and, once dismissed, never returns — `AppState` persists the
/// milestone so a relaunch doesn't re-celebrate.
struct FirstReclaimCelebration: View {
    @Environment(AppState.self) private var state
    @State private var dismissed = false

    var body: some View {
        if let bytes = state.firstReclaimMilestone, !dismissed {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("First cleanup: \(bytes.formattedBytes) freed")
                        .font(Theme.Font.bodyStrong)
                    Text("Empty the Trash in Finder whenever you're sure to get the space back.")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(8))
                dismiss()
            }
        }
    }

    private func dismiss() {
        withAnimation(.snappy) { dismissed = true }
        // Clear BOTH the in-memory flag and the persisted value. If only the
        // in-memory flag is cleared, the next launch re-reads the persisted
        // milestone from UserDefaults and re-shows the celebration — the
        // "pop-up on every launch" bug.
        state.firstReclaimMilestone = nil
        UserDefaults.standard.removeObject(forKey: "MacTidy.firstReclaimMilestone")
    }
}
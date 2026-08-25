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
                Text("🎉")
                    .font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You freed \(bytes.formattedBytes)!")
                        .font(.callout.bold())
                    Text("That's your first cleanup with MacTidy. Keep going — every pass adds up.")
                        .font(.caption).foregroundStyle(.secondary)
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(8))
                dismiss()
            }
        }
    }

    private func dismiss() {
        withAnimation(.snappy) { dismissed = true }
        // Clear the in-memory flag so a same-session second cleanup doesn't
        // re-fire it. The persisted value stays as the "already celebrated"
        // marker across relaunches.
        state.firstReclaimMilestone = nil
    }
}
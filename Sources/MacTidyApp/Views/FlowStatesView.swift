import SwiftUI
import CoreKit

/// The end-of-flow celebration. Everything queued has been cleaned up —
/// offer "Scan again" or finish.
struct AllCleanView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.bounce, value: state.flowPhase)
            VStack(spacing: Theme.Spacing.xs) {
                Text("You're all tidy")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Everything queued has been cleaned up.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            Button {
                Task { await state.startFlow() }
            } label: {
                Label("Scan again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Button("Done") {
                state.resetFlow()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
        .background(.linearGradient(
            colors: [Theme.accent.opacity(0.08), .clear],
            startPoint: .top, endPoint: .bottom
        ))
    }
}
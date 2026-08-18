import SwiftUI
import CoreKit

/// The end-of-flow celebration. Shows the total reclaimed this pass and
/// offers either "Run for real" (if it was a dry pass) or "Scan again".
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
                Text(state.flowPass == .dry ? "Preview complete" : "You're all tidy")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(state.flowPass == .dry
                     ? "That was a dry run — nothing was touched. Run it for real to reclaim the space."
                     : "Everything queued has been cleaned up.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if state.flowPass == .dry {
                Button {
                    withAnimation(.snappy) { state.startRealPass() }
                } label: {
                    Label("Run for real", systemImage: "checkmark.shield")
                        .font(.headline)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    Task { await state.startFlow() }
                } label: {
                    Label("Scan again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
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
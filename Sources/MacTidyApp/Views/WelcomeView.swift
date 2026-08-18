import SwiftUI
import CoreKit

/// The launch screen. One big call to action: Start Cleanup. The honest
/// subtitle tells the user up front that this is Move-to-Trash, reversible,
/// and that the first pass is a dry preview.
struct WelcomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
                Text("MacTidy")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Reclaim disk space, guided.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: Theme.Spacing.xs) {
                Text("MacTidy scans your Mac, then walks you through the biggest, safest things to clean — one at a time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Text("Deletion means Move to Trash. Your first pass is a dry preview — nothing is touched until you say so.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            Spacer()
            Button {
                Task { await state.startFlow() }
            } label: {
                Label("Start Cleanup", systemImage: "arrow.right.circle.fill")
                    .font(.title3.bold())
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
        .background(.linearGradient(
            colors: [Theme.accent.opacity(0.08), .clear],
            startPoint: .top, endPoint: .bottom
        ))
    }
}
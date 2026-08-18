import SwiftUI
import CoreKit

/// Full-bleed scanning state. A big animated ring with category progress, so
/// the wait feels intentional rather than a stuck spinner.
struct ScanningView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            ring
            VStack(spacing: Theme.Spacing.sm) {
                Text("Analyzing your Mac")
                    .font(.title2.bold())
                Text(state.scanProgress.isEmpty ? "Starting…" : state.scanProgress)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .animation(.snappy, value: state.scanProgress)
            }
            if state.scanTotal > 0 {
                ProgressView(value: Double(state.scanCompleted), total: Double(state.scanTotal))
                    .tint(Theme.accent)
                    .frame(maxWidth: 280)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
    }

    /// A ring that fills as categories complete, with a pulsing center icon.
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 6)
                .frame(width: 140, height: 140)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 140, height: 140)
                .animation(.snappy, value: state.scanCompleted)
            Image(systemName: "internaldrive")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, options: .repeating)
        }
    }

    private var fraction: Double {
        guard state.scanTotal > 0 else { return 0 }
        return Double(state.scanCompleted) / Double(state.scanTotal)
    }
}
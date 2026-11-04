import SwiftUI
import CoreKit

struct MemoryCard: View {
    @Environment(AppState.self) private var state
    @Binding var quitSheet: QuitTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Memory").font(Theme.Font.section)
                Spacer()
                if let pressure = state.memory.pressure {
                    Text("\(pressure.displayName) pressure")
                        .font(Theme.Font.caption).foregroundStyle(pressureColor)
                }
            }
            if let summary = state.memory.summary {
                HStack(spacing: Theme.Spacing.xxl) {
                    stat("Used", summary.usedBytes.formattedBytes)
                    stat("Available", summary.freeBytes.formattedBytes)
                    stat("Swap", summary.swapUsedBytes.formattedBytes)
                    stat("Installed", summary.totalBytes.formattedBytes)
                }
                Meter(fraction: Double(summary.usedBytes) / Double(max(summary.totalBytes, 1)),
                      tint: pressureColor, height: 5)
            }
            Text("macOS manages file caches automatically. Full RAM is normal; pressure and swap matter more.")
                .font(Theme.Font.caption).foregroundStyle(.secondary)
            ForEach(Array(state.memory.apps.prefix(5))) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    Text(app.footprintBytes?.formattedBytes ?? "Unavailable")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(Theme.Font.caption)
            }
            ForEach(Array(state.memory.apps.filter { state.memory.history.growth(for: $0.path) != nil }.prefix(3))) { app in
                if let growth = state.memory.history.growth(for: app.path) {
                    Text("\(app.name) grew by \(growth.formattedBytes) over at least two hours. This may be a leak; consider saving your work and restarting it.")
                        .font(Theme.Font.caption).foregroundStyle(.orange)
                }
            }
            Text("App memory includes helpers and compressed memory. Quitting may release less than the amount shown.")
                .font(Theme.Font.caption).foregroundStyle(.secondary)
            let candidates = Array(state.memory.candidates.prefix(5))
            if !candidates.isEmpty {
                Button("Review \(candidates.count) idle app\(candidates.count == 1 ? "" : "s") to quit…") {
                    quitSheet = QuitTarget(names: candidates.map(\.name))
                }
                .controlSize(.small)
            }
        }
        .cardStyle()
        .task { await state.memory.refresh() }
    }

    private var pressureColor: Color {
        switch state.memory.pressure {
        case .critical: .red
        case .warning: .orange
        default: Theme.accent
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.Font.figure)
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }
}

import SwiftUI
import CoreKit

/// The honest memory card. Shows the kernel's real pressure level (the number
/// that matters, not "bytes free") plus top idle consumers, and gates the two
/// legitimate actions on it: quitting idle apps, and — only under pressure —
/// purging the disk cache via an admin prompt.
struct MemoryCard: View {
    @Environment(AppState.self) private var state
    @Binding var quitSheet: QuitTarget?
    @State private var pressure: MemoryPressureLevel?
    @State private var summary: ProcessScanner.MemorySummary?
    @State private var idleApps: [RunningProcess] = []
    @State private var showPurgeConfirm = false
    @State private var isPurging = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").font(Theme.Font.section)
                Spacer()
                if let pressure {
                    HStack(spacing: 6) {
                        Circle().fill(pressureColor).frame(width: 7, height: 7)
                        Text("\(pressure.displayName) pressure")
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(pressureColor)
                    }
                }
            }
            if let summary {
                HStack(spacing: Theme.Spacing.xxl) {
                    stat("Used", summary.usedBytes.formattedBytes)
                    stat("Free", summary.freeBytes.formattedBytes)
                    stat("Swap", summary.swapUsedBytes.formattedBytes)
                    stat("Installed", summary.totalBytes.formattedBytes)
                }
                Meter(fraction: Double(summary.usedBytes) / Double(max(summary.totalBytes, 1)),
                      tint: pressureColor, height: 5)
            }
            Text("Full RAM is normal on macOS. Pressure and swap are what predict slowdowns.")
                .font(Theme.Font.caption).foregroundStyle(.secondary)

            HStack(spacing: Theme.Spacing.sm) {
                if !idleApps.isEmpty {
                    let bytes = idleApps.reduce(0) { $0 + $1.residentBytes }
                    Button {
                        quitSheet = QuitTarget(names: idleApps.map(\.name))
                    } label: {
                        Label("Quit \(idleApps.count) idle app\(idleApps.count == 1 ? "" : "s") · ~\(bytes.formattedBytes)",
                              systemImage: "power")
                    }
                    .controlSize(.small)
                }
                Button {
                    showPurgeConfirm = true
                } label: {
                    if isPurging {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Purging…") }
                    } else {
                        Label("Purge disk cache…", systemImage: "arrow.down.circle.dotted")
                    }
                }
                .controlSize(.small)
                .disabled(isPurging || (pressure.map { $0 < .warning } ?? true))
                .help(pressure.map { $0 >= .warning } ?? false
                      ? "Drops file caches so inactive memory shows as free. Needs an admin prompt."
                      : "Only useful under memory pressure.")
            }

            if case .purged = state.lastPurgeResult {
                Text("Disk cache purged. Caches will rebuild as you work.")
                    .font(.caption).foregroundStyle(Theme.Status.good)
            } else if case .adminPromptCancelled = state.lastPurgeResult {
                Text("Purge cancelled.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if case .failed(let message) = state.lastPurgeResult {
                Text("Purge failed: \(message)")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .cardStyle()
        .task { refreshSnapshot() }
        .confirmationDialog(
            "Purge the disk cache?",
            isPresented: $showPurgeConfirm,
            titleVisibility: .visible
        ) {
            Button("Purge with admin privileges") {
                Task { await runPurge() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This drops macOS's file caches, freeing inactive RAM. The effect is temporary — caches rebuild as apps run, and the next launches may be slightly slower. Most of the time, doing nothing is the right move.")
        }
    }

    private func refreshSnapshot() {
        pressure = MemoryPressure.currentLevel()
        summary = ProcessScanner.memorySummary()
        idleApps = Array(ProcessScanner.scan().filter(\.isSafeToQuit).prefix(5))
    }

    private var pressureColor: Color {
        switch pressure {
        case .critical: .red
        case .warning: .orange
        default: Theme.accent
        }
    }

    private func runPurge() async {
        isPurging = true
        defer { isPurging = false }
        state.purgeDiskCache()
        // Re-read pressure after purging so the gauge reflects reality.
        refreshSnapshot()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.Font.figure)
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }
}
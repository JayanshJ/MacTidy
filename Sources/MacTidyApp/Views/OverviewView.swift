import SwiftUI
import CoreKit

struct OverviewView: View {
    @Environment(AppState.self) private var state
    @State private var docker: DockerInfo.Usage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                reclaimCard
                categoryGrid
                dockerCard
                safetyCard
            }
            .padding(24)
        }
        .navigationTitle("Overview")
        .task {
            docker = await Task.detached { DockerInfo.usage() }.value
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.categoryResults.isEmpty && !state.isScanningCategories
                     ? "Not scanned yet"
                     : state.totalReclaimable.formattedBytes)
                    .font(.system(size: 40, weight: .bold))
                    .monospacedDigit()
                Text("reclaimable across cleanup categories")
                    .foregroundStyle(.secondary)
                if state.isScanningCategories {
                    Text(state.scanProgress.isEmpty ? "Scanning…" : state.scanProgress)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if !state.scanStatus.isEmpty {
                    Text(state.scanStatus).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if state.isScanningCategories {
                Button {
                    state.cancelScan()
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
                .controlSize(.large)
            } else {
                Button {
                    Task { await state.rescanCategories() }
                } label: {
                    Label("Scan Now", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
            }
        }
    }

    /// The honest "speed boost": a real, auditable total of bytes the user has
    /// actually moved to the Trash across every cleanup, plus the count.
    private var reclaimCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reclaim history", systemImage: "chart.bar.xaxis")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.totalReclaimedHistorically.formattedBytes)
                        .font(.title2.bold()).monospacedDigit()
                    Text("freed across \(state.cleanupHistory.count) cleanup\(state.cleanupHistory.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let last = state.cleanupHistory.first {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(last.reclaimedBytes.formattedBytes)
                            .font(.callout.bold()).monospacedDigit()
                        Text("last cleanup · \(last.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if state.cleanupHistory.isEmpty {
                Text("Run a cleanup (with Dry Run off) to start building this history. Only real cleanups are counted — never dry runs.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            ForEach(state.categoryResults) { result in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(result.category.displayName).font(.headline)
                        Spacer()
                        Text(result.totalBytes.formattedBytes)
                            .monospacedDigit()
                            .foregroundStyle(result.totalBytes > 0 ? .primary : .tertiary)
                    }
                    Text("\(result.items.count) item\(result.items.count == 1 ? "" : "s")"
                         + (result.category.isPreselectable ? "" : " · suggest-only"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var dockerCard: some View {
        if let docker {
            VStack(alignment: .leading, spacing: 8) {
                Label("Docker", systemImage: "shippingbox").font(.headline)
                Text("Docker data lives inside its VM disk — MacTidy can't reclaim it by trashing files. Current usage as reported by `docker system df`:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(docker.table)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Text(DockerInfo.pruneCommand)
                        .font(.system(.callout, design: .monospaced))
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DockerInfo.pruneCommand, forType: .string)
                    }
                    Text("Run it yourself in a terminal — MacTidy won't.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var safetyCard: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 8) {
            Label("Safety", systemImage: "shield").font(.headline)
            Toggle("Dry run — preview deletions without touching anything", isOn: $state.dryRun)
            Text("Deletion always means Move to Trash. A hard denylist protects /System, your documents, photos, and media no matter what a scan proposes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
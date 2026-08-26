import SwiftUI
import CoreKit

/// Inspector for Node projects: finds projects under the dev roots and offers
/// one reclaim action per project — `npm prune` when there are orphaned
/// packages (safe, keeps the tree working), or trashing the whole
/// `node_modules` dir when it's already clean. One row per project.
struct NodePackagesInspector: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var analyses: [NodeProjectAnalysis] = []
    @State private var isLoading = false
    @State private var sheetPlan: DeletionPlan?
    @State private var pruneStatus: [String: String] = [:]

    private var devRoots: [URL] { CategoryScanner.defaultDevRoots }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Node Packages").font(.headline)
                Spacer()
                Button { Task { await scan() } } label: {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Label("Rescan", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
            Divider()
            if isLoading && analyses.isEmpty {
                ProgressView("Scanning Node projects…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if analyses.isEmpty {
                ContentUnavailableView(
                    "No Node projects found",
                    systemImage: "shippingbox",
                    description: Text("No directories under your dev roots contain both package.json and node_modules.")
                )
            } else {
                List {
                    ForEach(analyses) { analysis in
                        projectRow(analysis)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .task { if analyses.isEmpty { await scan() } }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Trash node_modules?", plan: plan) { _ in
                Task { await scan() }
            }
        }
    }

    @ViewBuilder
    private func projectRow(_ analysis: NodeProjectAnalysis) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(analysis.projectDir.lastPathComponent).fontWeight(.medium)
                HStack(spacing: 6) {
                    Text(analysis.nodeModulesBytes.formattedBytes)
                    Text("·")
                    if analysis.orphaned.isEmpty {
                        Text("clean").foregroundStyle(.secondary)
                    } else {
                        Text("\(analysis.orphaned.count) orphaned")
                            .foregroundStyle(Theme.accent)
                    }
                    if !analysis.orphaned.isEmpty {
                        Text(analysis.orphaned.joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .font(.caption.monospacedDigit())
                Text(analysis.projectDir.path)
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
                if let status = pruneStatus[analysis.projectDir.path] {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if analysis.orphaned.isEmpty {
                // Nothing to prune — offer to reclaim the whole dir.
                Button {
                    sheetPlan = DeletionPlan(items: [ScanItem(
                        url: analysis.projectDir.appending(path: "node_modules"),
                        sizeBytes: analysis.nodeModulesBytes, isDirectory: true)])
                } label: {
                    Text("Trash").frame(minWidth: 56)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Move the whole node_modules to Trash. Restore with `npm install`.")
            } else {
                Button {
                    Task { await runPrune(in: analysis.projectDir) }
                } label: {
                    Text("Clean").frame(minWidth: 56)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Safe — removes the \(analysis.orphaned.count) orphaned package(s); the project keeps working. Reversible via npm install.")
            }
        }
        .padding(.vertical, 2)
    }

    private func scan() async {
        isLoading = true
        let projects = NodePackageAnalyzer.findProjects(under: devRoots)
        var results: [NodeProjectAnalysis] = []
        for project in projects {
            if let analysis = NodePackageAnalyzer.analyze(project) {
                results.append(analysis)
            }
        }
        analyses = results.sorted { $0.nodeModulesBytes > $1.nodeModulesBytes }
        isLoading = false
    }

    /// Runs `npm prune` in the project dir. This is the safe reclaim action —
    /// it removes orphaned packages while keeping the declared dependency
    /// tree intact and the project working. Uses the user's npm via Shell.
    private func runPrune(in dir: URL) async {
        let key = dir.path
        let npm = Shell.find("npm") ?? "/usr/local/bin/npm"
        guard FileManager.default.isExecutableFile(atPath: npm) else {
            await MainActor.run { pruneStatus[key] = "npm not found." }
            return
        }
        let out = Shell.run(npm, ["prune", "--prefix", dir.path])
        await MainActor.run {
            pruneStatus[key] = out?.succeeded == true
                ? "Done — orphaned packages removed."
                : "npm prune failed: \(out?.stderr ?? "unknown")"
        }
        // Refresh this project's row so the button flips Clean → Trash.
        if let updated = NodePackageAnalyzer.analyze(dir),
           let idx = analyses.firstIndex(where: { $0.id == updated.id }) {
            await MainActor.run { analyses[idx] = updated }
        }
    }
}
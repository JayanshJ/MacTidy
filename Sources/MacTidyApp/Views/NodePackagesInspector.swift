import SwiftUI
import CoreKit

/// Inspector for Node projects: finds projects under the dev roots, runs the
/// orphaned/unused package analysis, and offers `npm prune` (safe, keeps the
/// project working) or whole-dir trash. Never trashes individual packages out
/// of a live node_modules — npm expects that tree to be coherent.
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
                        projectSection(analysis)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .task { if analyses.isEmpty { await scan() } }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Trash node_modules?", plan: plan) { outcome in
                if !outcome.dryRun { Task { await scan() } }
            }
        }
    }

    @ViewBuilder
    private func projectSection(_ analysis: NodeProjectAnalysis) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(analysis.projectDir.lastPathComponent).fontWeight(.medium)
                    Text(analysis.projectDir.path)
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Text("\(analysis.totalInstalledPackages) pkgs · \(analysis.nodeModulesBytes.formattedBytes)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !analysis.orphaned.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(analysis.orphaned.count) orphaned packages — not in package.json", systemImage: "checkmark.seal")
                        .font(.caption.bold())
                    Text(analysis.orphaned.joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            if !analysis.unused.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(analysis.unused.count) possibly unused — in package.json but not imported", systemImage: "exclamationmark.triangle")
                        .font(.caption.bold())
                    Text(analysis.unused.joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text("Heuristic — verify before removing. Dynamic imports, polyfill-only deps, and build plugins can cause false positives.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            // Always show both reclaim actions per project.
            HStack {
                Button {
                    Task { await runPrune(in: analysis.projectDir) }
                } label: {
                    Label("Run npm prune", systemImage: "hammer")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(analysis.orphaned.isEmpty)
                .help(analysis.orphaned.isEmpty
                      ? "No orphaned packages detected."
                      : "Safe — removes orphaned packages; the project keeps working. Reversible via npm install.")
                if let status = pruneStatus[analysis.projectDir.path] {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    sheetPlan = DeletionPlan(items: [ScanItem(url: analysis.projectDir.appending(path: "node_modules"),
                                                               sizeBytes: analysis.nodeModulesBytes, isDirectory: true)])
                } label: {
                    Label("Trash whole node_modules", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if analysis.orphaned.isEmpty && analysis.unused.isEmpty {
                Text("Clean — no orphaned or unused packages detected. Trash the whole dir to reclaim all space, then `npm install` to restore.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Safe: npm prune keeps the tree working. Trash whole dir: reversible via Trash, `npm install` to restore.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        } header: {
            Text(analysis.projectDir.lastPathComponent).font(.headline)
        }
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
    }
}
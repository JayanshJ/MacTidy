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
    @State private var pendingPrune: [any ShellAction] = []
    @State private var showPruneSheet = false
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
        .sheet(isPresented: $showPruneSheet) {
            ShellActionConfirmationSheet(
                title: "Run npm prune?",
                actions: pendingPrune,
                kind: .devTerminal,
                note: "Removes orphaned packages — those listed in package.json but no longer installed. The project keeps working. Reversible via npm install.",
                onCompleted: {
                    // Record the status per-project so the row shows the result.
                    Task { await scan() }
                }
            )
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
                    pendingPrune = [NpmPruneAction(
                        projectDir: analysis.projectDir,
                        orphanedCount: analysis.orphaned.count
                    )]
                    showPruneSheet = true
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
}
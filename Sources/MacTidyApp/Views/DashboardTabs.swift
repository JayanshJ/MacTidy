import SwiftUI
import CoreKit

/// Uninstaller tab on the dashboard. List of non-Apple apps with their
/// leftover data; multi-select an app's leftovers + the app itself, then
/// Uninstall via the confirmation sheet. Reuses AppState's flowApps scan.
struct DashboardUninstaller: View {
    @Environment(AppState.self) private var state
    @State private var selectedAppID: String?
    @State private var leftoverSelection = Set<UUID>()
    @State private var sheetPlan: DeletionPlan?
    @State private var leftovers: [ScanItem] = []
    @State private var isLoadingLeftovers = false
    @State private var actions: [UninstallAction] = []

    private var selectedApp: (app: InstalledApp, leftovers: [ScanItem])? {
        state.flowApps.first { $0.app.id == selectedAppID }
    }

    var body: some View {
        HStack(spacing: 0) {
            appList
                .frame(minWidth: 280, idealWidth: 320)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selectedAppID) { Task { await loadLeftovers() } }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Uninstall \(selectedApp?.app.name ?? "app")?",
                                      plan: plan,
                                      kind: .uninstall,
                                      uninstallActions: actions) { outcome in
                if !outcome.dryRun {
                    selectedAppID = nil
                    leftovers = []
                    actions = []
                    Task { await state.startFlow() }
                }
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                Text("\(state.flowApps.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
            Divider()
            if state.flowApps.isEmpty {
                ContentUnavailableView("No apps to uninstall",
                                       systemImage: "trash.slash",
                                       description: Text("Only large non-Apple apps are listed."))
            } else {
                List(state.flowApps, id: \.app.id, selection: $selectedAppID) { entry in
                    HStack {
                        Text(entry.app.name).lineLimit(1)
                        Spacer()
                        Text(entry.app.sizeBytes.formattedBytes)
                            .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(entry.app.id)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedApp {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(entry.app.name).font(.title2.bold())
                    Text(entry.app.bundleID ?? "no bundle identifier")
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                    Text("App bundle: \(entry.app.sizeBytes.formattedBytes)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding()
                Divider()
                if isLoadingLeftovers {
                    ProgressView("Searching for leftover data…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Leftover data (\(leftovers.count))")
                                .font(.headline)
                            Spacer()
                            if !leftovers.isEmpty {
                                Button {
                                    let allSelected = leftovers.allSatisfy { leftoverSelection.contains($0.id) }
                                    leftoverSelection.removeAll()
                                    if !allSelected {
                                        for item in leftovers { leftoverSelection.insert(item.id) }
                                    }
                                } label: {
                                    let allSelected = leftovers.allSatisfy { leftoverSelection.contains($0.id) }
                                    Label(allSelected ? "Deselect All" : "Select All",
                                          systemImage: allSelected ? "circle" : "checkmark.circle")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
                        Divider()
                        List {
                            Section {
                                if leftovers.isEmpty {
                                    Text("No orphaned data found for this app.").foregroundStyle(.tertiary)
                                }
                                ForEach(leftovers) { item in
                                    ScanItemRow(item: item, selection: $leftoverSelection)
                                }
                            } footer: {
                                if !actions.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Also runs on uninstall:")
                                            .font(.caption.bold())
                                        ForEach(actions) { action in
                                            HStack(spacing: 6) {
                                                Image(systemName: action.kind.icon)
                                                    .foregroundStyle(Theme.accent)
                                                Text(action.kind.rawValue)
                                            }
                                            .font(.caption)
                                        }
                                        Text("These run automatically with the uninstall — privacy permissions are revoked and the app is unregistered from LaunchServices.")
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        SelectionFooter(
                            selectedCount: leftoverSelection.count + 1,
                            selectedBytes: entry.app.sizeBytes + selectedLeftovers.reduce(0) { $0 + $1.sizeBytes },
                            buttonTitle: "Uninstall…",
                            disabled: false
                        ) {
                            var items = selectedLeftovers
                            items.insert(ScanItem(url: entry.app.url, sizeBytes: entry.app.sizeBytes,
                                                  isDirectory: true), at: 0)
                            sheetPlan = DeletionPlan(items: items)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Pick an app",
                                   systemImage: "trash.slash",
                                   description: Text("Select an app to see its bundle plus leftover data in ~/Library. Privacy permissions are revoked and LaunchServices registration dropped on uninstall."))
        }
    }

    private var selectedLeftovers: [ScanItem] {
        leftovers.filter { leftoverSelection.contains($0.id) }
    }

    private func loadLeftovers() async {
        guard let entry = selectedApp else { leftovers = []; actions = []; return }
        isLoadingLeftovers = true
        leftovers = await AppUninstaller.leftovers(for: entry.app)
        leftoverSelection = Set(leftovers.map(\.id))
        actions = AppUninstaller.actions(for: entry.app)
        isLoadingLeftovers = false
    }
}

/// Startup Items tab on the dashboard. Lists launch agents/daemons across all
/// three domains with Disable actions. Reuses the existing LaunchItemsAuditor.
struct DashboardStartup: View {
    @Environment(AppState.self) private var state
    @State private var items: [LaunchItem] = []
    @State private var disabledItems: [LaunchItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Startup Items").font(.title3.bold())
                Spacer()
                Button { reload() } label: {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Label("Rescan", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isLoading)
            }
            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
            Divider()
            List {
                ForEach(LaunchItem.Domain.allCases, id: \.self) { domain in
                    section(for: domain)
                }
                if !disabledItems.isEmpty {
                    Section("Disabled by MacTidy") {
                        ForEach(disabledItems) { item in row(item, action: .restore) }
                    }
                }
            }
            .overlay { if isLoading { ProgressView("Reading launchd plists…") } }
        }
        .onAppear { if items.isEmpty { reload() } }
        .alert("Startup item change failed",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func section(for domain: LaunchItem.Domain) -> some View {
        let domainItems = items.filter { $0.domain == domain }
        Section {
            if domainItems.isEmpty { Text("None found").foregroundStyle(.tertiary) }
            ForEach(domainItems) { item in row(item, action: .disable) }
        } header: { Text(domain.rawValue) }
        footer: {
            if domain.requiresAdmin {
                Text("Needs admin rights — macOS will prompt for your password.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private enum RowAction { case disable, restore }

    @ViewBuilder
    private func row(_ item: LaunchItem, action: RowAction?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).fontWeight(.medium).lineLimit(1)
                    if item.isLoaded { Badge(text: "Loaded", tint: Theme.Status.good, filled: true) }
                    if item.runAtLoad == true { Badge(text: "Runs at login", tint: .blue) }
                    if item.domain.requiresAdmin { Badge(text: "Admin", tint: Theme.Status.caution) }
                }
                if let program = item.program {
                    Text(program).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            switch action {
            case .disable: Button("Disable") { disable(item) }
            case .restore: Button("Restore") { restore(item) }
            case nil: EmptyView()
            }
        }
    }

    private func reload() {
        isLoading = true
        Task {
            let (audited, parked) = await Task.detached {
                (LaunchItemsAuditor.audit(), LaunchItemsAuditor.disabledItems())
            }.value
            items = audited; disabledItems = parked; isLoading = false
        }
    }

    private func disable(_ item: LaunchItem) {
        do { try LaunchItemsAuditor.disable(item); reload() }
        catch { errorMessage = error.localizedDescription }
    }

    private func restore(_ item: LaunchItem) {
        do { try LaunchItemsAuditor.restore(item); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}
/// "Storage by App" tab: shows which installed app is using how much space
/// across ~/Library, with drill-in to the exact paths bucketed by kind
/// (Caches, App Support, Containers, …). The "where exactly" answer. Offers a
/// "Trash caches only" action per app that keeps the app but reclaims its
/// caches — safe and reversible, since caches rebuild.
struct StorageByAppTab: View {
    @Environment(AppState.self) private var state
    @State private var attributions: [AppFootprint] = []
    @State private var isLoading = false
    @State private var selectedAppID: String?
    @State private var sheetPlan: DeletionPlan?

    private var selected: AppFootprint? { attributions.first { $0.app.id == selectedAppID } }

    var body: some View {
        HStack(spacing: 0) {
            appList.frame(minWidth: 300, idealWidth: 340)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if attributions.isEmpty { await load() } }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(
                title: "Trash caches for \(selected?.app.name ?? "app")?",
                plan: plan
            ) { outcome in
                if !outcome.dryRun { Task { await load() } }
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                Button { Task { await load() } } label: {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
            Divider()
            if attributions.isEmpty {
                ContentUnavailableView(
                    isLoading ? "Scanning…" : "No app data found",
                    systemImage: "person.crop.square",
                    description: Text(isLoading
                        ? "Matching ~/Library folders to your apps."
                        : "No app-attributable library data. Run a rescan from the Cleanup tab first.")
                )
            } else {
                List(attributions, id: \.app.id, selection: $selectedAppID) { entry in
                    HStack {
                        Text(entry.app.name).lineLimit(1)
                        Spacer()
                        Text(entry.totalBytes.formattedBytes)
                            .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(entry.app.id)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(entry.app.name).font(.title2.bold())
                    Text(entry.app.bundleID ?? "no bundle identifier")
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                    Text("App bundle \(entry.app.sizeBytes.formattedBytes) · library data \(entry.libraryBytes.formattedBytes) · total \(entry.totalBytes.formattedBytes)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding()
                Divider()
                List {
                    Section("Where the \(entry.libraryBytes.formattedBytes) lives") {
                        ForEach(entry.bucketTotals, id: \.0) { bucket, bytes in
                            HStack {
                                Text(bucket.displayName)
                                Spacer()
                                Text(bytes.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Paths (largest first)") {
                        ForEach(entry.paths) { path in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(path.url.lastPathComponent).lineLimit(1)
                                    Text(path.url.path)
                                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                Spacer()
                                Text(path.sizeBytes.formattedBytes)
                                    .monospacedDigit().foregroundStyle(.secondary)
                                Button { showInFinder(path.url) } label: {
                                    Image(systemName: "magnifyingglass.circle")
                                }
                                .buttonStyle(.borderless).help("Show in Finder")
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        let caches = entry.paths.filter { $0.bucket == .caches }
                        sheetPlan = DeletionPlan(items: caches.map { ScanItem(url: $0.url, sizeBytes: $0.sizeBytes, isDirectory: true) })
                    } label: {
                        Label("Trash Caches Only…", systemImage: "trash.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(entry.paths.allSatisfy { $0.bucket != .caches })
                    .help("Move only this app's caches to the Trash. The app stays installed; caches rebuild on next launch. Reversible.")
                }
                .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.md)
            }
        } else {
            ContentUnavailableView("Pick an app",
                                   systemImage: "person.crop.square",
                                   description: Text("See exactly where each app keeps its data in ~/Library, and reclaim its caches without uninstalling."))
        }
    }

    private func load() async {
        isLoading = true
        let apps = await AppUninstaller.installedApps()
        let result = await AppStorageAttribution.scan(apps: apps)
        attributions = result
        isLoading = false
    }
}

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

/// Proactive "AI Insights" panel: the AI (or the deterministic fallback)
/// reasons over disk + memory + processes and surfaces narrative insights
/// with a proposed action. Each action routes through the existing
/// confirmation flow — trash via DeletionConfirmationSheet, quit-apps via a
/// dedicated sheet. The model never executes.
struct InsightsTab: View {
    @Environment(AppState.self) private var state
    @State private var insights: [Insight] = []
    @State private var isLoading = false
    @State private var sheetPlan: DeletionPlan?
    @State private var quitSheet: QuitTarget?
    @State private var usingAI = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Trash suggested items?", plan: plan) { outcome in
                if !outcome.dryRun { Task { await refresh() } }
            }
        }
        .sheet(item: $quitSheet) { target in
            QuitConfirmationSheet(apps: target.names) { didQuit in
                if didQuit { Task { await refresh() } }
            }
        }
        .task { if insights.isEmpty { await refresh() } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Insights").font(.title3.bold())
                Text(usingAI ? "Reasoned by your configured AI model." : "Generated locally — add an AI provider in Settings for richer reasoning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await refresh() } } label: {
                if isLoading {
                    HStack { ProgressView().controlSize(.small); Text("Thinking…") }
                } else {
                    Label("Refresh", systemImage: "sparkles")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isLoading)
        }
        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if insights.isEmpty && !isLoading {
            ContentUnavailableView(
                "Nothing to suggest",
                systemImage: "checkmark.seal",
                description: Text("No reclaimable disk, no idle memory hogs, and the OS isn't under pressure. You're tidy.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading && insights.isEmpty {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Reasoning over your disk, memory, and processes…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    MemoryCard(quitSheet: $quitSheet)
                    ForEach(insights) { insight in
                        insightCard(insight)
                    }
                }
                .padding(Theme.Spacing.xl)
            }
        }
    }

    private func insightCard(_ insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: insight.kind.icon).foregroundStyle(Theme.accent)
                Text(insight.kind.rawValue).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if insight.reclaimableBytes > 0 {
                    Text("~\(insight.reclaimableBytes.formattedBytes) reclaimable")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                }
            }
            Text(insight.reasoning).font(.callout)
            actionButton(for: insight)
        }
        .padding(Theme.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    @ViewBuilder
    private func actionButton(for insight: Insight) -> some View {
        switch insight.action {
        case .trash(let items):
            Button {
                sheetPlan = DeletionPlan(items: items)
            } label: {
                Label("Trash these · \(insight.reclaimableBytes.formattedBytes)", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .quitApps(let names):
            Button {
                quitSheet = QuitTarget(names: names)
            } label: {
                Label("Quit \(names.joined(separator: ", "))", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .observe:
            Text("No action — just so you know.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func refresh() async {
        isLoading = true
        usingAI = state.aiConfig.provider != .none && state.advisor != nil
        let result = await state.generateInsights()
        insights = result
        isLoading = false
    }
}

/// Wraps an app-name list so it can drive a `.sheet(item:)`.
struct QuitTarget: Identifiable {
    let names: [String]
    var id: String { names.joined(separator: "|") }
}

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
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "memorychip").foregroundStyle(Theme.accent)
                Text("Memory").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if let pressure {
                    HStack(spacing: 4) {
                        Circle().fill(pressureColor).frame(width: 8, height: 8)
                        Text("Pressure: \(pressure.displayName)")
                            .font(.caption.bold())
                            .foregroundStyle(pressureColor)
                    }
                } else {
                    Text("Pressure unavailable")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            if let summary {
                HStack(spacing: Theme.Spacing.lg) {
                    stat("Used", summary.usedBytes.formattedBytes)
                    stat("Free", summary.freeBytes.formattedBytes)
                    stat("Swap", summary.swapUsedBytes.formattedBytes)
                    stat("Total", summary.totalBytes.formattedBytes)
                }
            }
            Text("Full RAM is normal on macOS — cached memory is reclaimed instantly when needed. Pressure and swap are what predict trouble.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: Theme.Spacing.sm) {
                if !idleApps.isEmpty {
                    let bytes = idleApps.reduce(0) { $0 + $1.residentBytes }
                    Button {
                        quitSheet = QuitTarget(names: idleApps.map(\.name))
                    } label: {
                        Label("Quit \(idleApps.count) idle app\(idleApps.count == 1 ? "" : "s") · ~\(bytes.formattedBytes)",
                              systemImage: "power")
                    }
                    .buttonStyle(.borderedProminent)
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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isPurging || (pressure.map { $0 < .warning } ?? true))
                .help(pressure != nil && pressure! >= .warning
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
        .padding(Theme.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
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
        default: Theme.Status.good
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
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Confirmation sheet for quitting apps. Shows which apps and the RAM that
/// would free, then runs `osascript -e 'tell app "Foo" to quit'` per app —
/// graceful quit, not a kill -9, so apps can save state.
struct QuitConfirmationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let apps: [String]
    let onCompleted: (Bool) -> Void
    @State private var results: [(String, Bool)] = []
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quit these apps?").font(.title2.bold())
            Text("A graceful quit (not force-kill), so each app can save its state. You can reopen them anytime.")
                .foregroundStyle(.secondary)
            List {
                ForEach(apps, id: \.self) { name in
                    HStack {
                        Image(systemName: appIcon(for: name))
                        Text(name)
                        Spacer()
                        if let r = results.first(where: { $0.0 == name }) {
                            Image(systemName: r.1 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.1 ? Theme.Status.good : .red)
                        }
                    }
                }
            }
            .listStyle(.bordered)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(done ? "Done" : "Quit") { quit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(done)
            }
        }
        .padding(20)
        .frame(width: 460, height: 320)
    }

    private func appIcon(for name: String) -> String { "app.dashed" }

    private func quit() {
        // Graceful quit via AppleScript — apps get a chance to save state,
        // unlike kill -9. Never used on denied/system processes (the resolver
        // already filtered those out before the insight reached here).
        for name in apps {
            let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "tell application \"\(escaped)\" to quit"
            let out = Shell.run("/usr/bin/osascript", ["-e", script])
            results.append((name, out?.succeeded ?? false))
        }
        done = true
        onCompleted(true)
    }
}

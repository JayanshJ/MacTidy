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
                                      plan: plan, kind: .uninstall) { outcome in
                if !outcome.dryRun {
                    selectedAppID = nil
                    leftovers = []
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
                    List {
                        Section("Leftover data (\(leftovers.count))") {
                            if leftovers.isEmpty {
                                Text("No orphaned data found for this app.").foregroundStyle(.tertiary)
                            }
                            ForEach(leftovers) { item in
                                ScanItemRow(item: item, selection: $leftoverSelection)
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
        } else {
            ContentUnavailableView("Pick an app",
                                   systemImage: "trash.slash",
                                   description: Text("Select an app to see its bundle plus leftover data in ~/Library."))
        }
    }

    private var selectedLeftovers: [ScanItem] {
        leftovers.filter { leftoverSelection.contains($0.id) }
    }

    private func loadLeftovers() async {
        guard let entry = selectedApp else { leftovers = []; return }
        isLoadingLeftovers = true
        leftovers = await AppUninstaller.leftovers(for: entry.app)
        leftoverSelection = Set(leftovers.map(\.id))
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
        .toolbar {
            Button { reload() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(isLoading)
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
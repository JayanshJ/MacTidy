import SwiftUI
import CoreKit

/// How the Uninstaller app list is ordered. Defaults to `lastOpened` so the
/// apps you forgot you had surface first; `size` keeps the legacy ranking.
enum AppSortMode: String, CaseIterable, Identifiable {
    case size
    case lastOpened
    var id: String { rawValue }
    var label: String {
        switch self {
        case .size: "By size"
        case .lastOpened: "By last opened"
        }
    }
}

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
    /// Sort mode for the app list. Defaults to "by last opened" so the apps
    /// you forgot you had surface first — the whole point of unused-app
    /// detection. Size is still available for users who want it.
    @State private var sortMode: AppSortMode = .lastOpened

    private var selectedApp: (app: InstalledApp, leftovers: [ScanItem])? {
        state.flowApps.first { $0.app.id == selectedAppID }
    }

    /// Apps reordered for the current sort mode. `flowApps` is kept
    /// size-descended (the flow-queue ranking depends on it); the view
    /// re-sorts a copy for display only.
    private var sortedApps: [(app: InstalledApp, leftovers: [ScanItem])] {
        switch sortMode {
        case .size:
            return state.flowApps
        case .lastOpened:
            return state.flowApps.sorted { AppUninstaller.byLastOpened($0.app, $1.app) }
        }
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
                                       uninstallActions: actions) { _ in
                // Stay on the dashboard: drop the uninstalled app from the
                // list and clear the detail pane instead of triggering a full
                // rescan + phase change. The app bundle is already in the
                // Trash, so a rescan would just re-list every category with
                // the same data minus one app — wasteful and disorienting.
                if let id = selectedAppID { state.refreshAfterUninstall(appID: id) }
                selectedAppID = nil
                leftovers = []
                actions = []
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                Picker("Sort", selection: $sortMode) {
                    ForEach(AppSortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                Text("\(state.flowApps.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
            Divider()
            if state.flowApps.isEmpty {
                ContentUnavailableView("No apps to uninstall",
                                       systemImage: "trash.slash",
                                       description: Text("Only large non-Apple apps are listed."))
            } else {
                List(sortedApps, id: \.app.id, selection: $selectedAppID) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.app.name).lineLimit(1)
                            Text(AppUninstaller.lastUsedLabel(for: entry.app.lastUsedDate))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
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
                    Text("Last opened: \(lastOpenedAbsolute(entry.app.lastUsedDate))")
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

    /// Absolute date for the detail header ("Mar 4, 2024"), "Never" when
    /// Spotlight has no record.
    private func lastOpenedAbsolute(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(.dateTime.year().month().day())
    }
}
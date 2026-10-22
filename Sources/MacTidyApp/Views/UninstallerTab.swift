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
                .frame(width: 320)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .task { await state.loadAppsIfNeeded() }
        .onChange(of: selectedAppID) { Task { await loadLeftovers() } }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Uninstall \(selectedApp?.app.name ?? "app")?",
                                       plan: plan,
                                       kind: .uninstall,
                                       uninstallActions: actions) { _ in
                // Drop the app from the list instead of a full rescan.
                if let id = selectedAppID { state.refreshAfterUninstall(appID: id) }
                selectedAppID = nil
                leftovers = []
                actions = []
            }
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Uninstaller").font(Theme.Font.title)
                HStack {
                    Text("\(state.flowApps.count) apps").font(Theme.Font.body).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Sort", selection: $sortMode) {
                        ForEach(AppSortMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.md)
            if state.flowApps.isEmpty {
                Group {
                    if state.isLoadingApps {
                        ProgressView("Finding apps")
                    } else {
                        EmptyStateView(symbol: "xmark.app", title: "No apps to remove",
                                       message: "Only non-Apple apps over 50 MB are listed.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sortedApps, id: \.app.id) { entry in
                            appRow(entry.app)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Spacing.lg)
                }
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let selected = selectedAppID == app.id
        return Button { selectedAppID = app.id } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(Theme.Font.bodyStrong).lineLimit(1)
                    Text(AppUninstaller.lastUsedLabel(for: app.lastUsedDate))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Spacing.sm)
                Text(app.sizeBytes.formattedBytes)
                    .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 7)
            .background(selected ? Theme.accent.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedApp {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        HStack(spacing: Theme.Spacing.lg) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.app.url.path))
                                .resizable().frame(width: 64, height: 64)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(entry.app.name).font(Theme.Font.title)
                                Text("\(entry.app.sizeBytes.formattedBytes)  ·  last opened \(lastOpenedAbsolute(entry.app.lastUsedDate))")
                                    .font(Theme.Font.body).foregroundStyle(.secondary)
                                if let id = entry.app.bundleID {
                                    Text(id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if isLoadingLeftovers {
                            ProgressView("Looking for leftover data").frame(maxWidth: .infinity)
                        } else if leftovers.isEmpty {
                            Text("No leftover data in ~/Library for this app.")
                                .font(Theme.Font.body).foregroundStyle(.secondary)
                        } else {
                            let all = leftovers.allSatisfy { leftoverSelection.contains($0.id) }
                            SurfaceSection("Leftover data", footer: actionsNote) {
                                Button(all ? "Deselect All" : "Select All") {
                                    leftoverSelection = all ? [] : Set(leftovers.map(\.id))
                                }
                                .buttonStyle(.link)
                                .font(Theme.Font.caption)
                            } content: {
                                ForEach(Array(leftovers.enumerated()), id: \.element.id) { i, item in
                                    if i > 0 { RowDivider(inset: 70) }
                                    ScanItemRow(item: item, selection: $leftoverSelection)
                                        .padding(.horizontal, Theme.Spacing.lg)
                                        .padding(.vertical, Theme.Spacing.xs)
                                }
                            }
                        }
                    }
                    .padding(Theme.gutter)
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
        } else {
            EmptyStateView(symbol: "xmark.app", title: "Choose an app",
                           message: "See the app and everything it left in ~/Library. Uninstalling also revokes its privacy permissions.")
                .frame(maxHeight: .infinity)
        }
    }

    private var actionsNote: String? {
        guard !actions.isEmpty else { return nil }
        return "Uninstalling also runs: " + actions.map(\.kind.rawValue).joined(separator: ", ") + "."
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
import SwiftUI
import CoreKit

struct UninstallerView: View {
    @State private var apps: [InstalledApp] = []
    @State private var isLoading = false
    @State private var search = ""
    @State private var selectedAppID: String?
    @State private var leftovers: [ScanItem] = []
    @State private var isLoadingLeftovers = false
    @State private var leftoverSelection = Set<UUID>()
    @State private var sheetPlan: DeletionPlan?

    private var filteredApps: [InstalledApp] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var selectedApp: InstalledApp? {
        apps.first { $0.id == selectedAppID }
    }

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 260, idealWidth: 300)
            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Uninstaller")
        .task { await loadApps() }
        .onChange(of: selectedAppID) {
            Task { await loadLeftovers() }
        }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Uninstall \(selectedApp?.name ?? "app")?",
                                      plan: plan) { outcome in
                if !outcome.dryRun {
                    selectedAppID = nil
                    leftovers = []
                    Task { await loadApps() }
                }
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            if isLoading {
                ProgressView("Reading /Applications…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredApps, selection: $selectedAppID) { app in
                    HStack {
                        Text(app.name).lineLimit(1)
                        if app.isApple {
                            Text("Apple")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .background(.quaternary, in: Capsule())
                        }
                        Spacer()
                        Text(app.sizeBytes.formattedBytes)
                            .monospacedDigit()
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(app.id)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let app = selectedApp {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.title2.bold())
                    Text(app.bundleID ?? "no bundle identifier")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    Text("App bundle: \(app.sizeBytes.formattedBytes)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if app.isApple {
                        Label("Apple system app — uninstalling is disabled.",
                              systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                            .padding(.top, 4)
                    }
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
                                Text("No orphaned data found for this app.")
                                    .foregroundStyle(.tertiary)
                            }
                            ForEach(leftovers) { item in
                                ScanItemRow(item: item, selection: $leftoverSelection)
                            }
                        }
                    }
                    SelectionFooter(
                        selectedCount: leftoverSelection.count + 1, // +1 = the .app itself
                        selectedBytes: app.sizeBytes + selectedLeftovers.reduce(0) { $0 + $1.sizeBytes },
                        buttonTitle: "Uninstall…",
                        disabled: app.isApple
                    ) {
                        var items = selectedLeftovers
                        items.insert(ScanItem(url: app.url, sizeBytes: app.sizeBytes, isDirectory: true), at: 0)
                        sheetPlan = DeletionPlan(items: items)
                    }
                }
            }
        } else {
            ContentUnavailableView("Pick an app",
                                   systemImage: "trash.slash",
                                   description: Text("Select an app to see its bundle plus every piece of data it left in ~/Library."))
        }
    }

    private var selectedLeftovers: [ScanItem] {
        leftovers.filter { leftoverSelection.contains($0.id) }
    }

    private func loadApps() async {
        isLoading = true
        apps = await AppUninstaller.installedApps()
        isLoading = false
    }

    private func loadLeftovers() async {
        guard let app = selectedApp else {
            leftovers = []
            return
        }
        isLoadingLeftovers = true
        leftovers = await AppUninstaller.leftovers(for: app)
        // Preselect all leftovers — they're orphaned once the app is gone.
        leftoverSelection = Set(leftovers.map(\.id))
        isLoadingLeftovers = false
    }
}

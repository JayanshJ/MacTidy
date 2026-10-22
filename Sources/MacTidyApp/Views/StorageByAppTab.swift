import SwiftUI
import CoreKit

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
            appList.frame(width: 320)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .task {
            if !state.appAttributions.isEmpty {
                attributions = state.appAttributions
            } else if attributions.isEmpty {
                await load()
            }
        }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(
                title: "Trash caches for \(selected?.app.name ?? "app")?",
                plan: plan
            ) { _ in
                Task { await load() }
            }
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("App Storage").font(Theme.Font.title)
                HStack {
                    Text("Data each app keeps in ~/Library").font(Theme.Font.body).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await load() } } label: {
                        if isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                    .help("Refresh")
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.md)
            if attributions.isEmpty {
                Group {
                    if isLoading { ProgressView("Matching folders to apps") }
                    else { EmptyStateView(symbol: "square.stack.3d.up", title: "No app data found") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let largest = attributions.map(\.totalBytes).max() ?? 1
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(attributions, id: \.app.id) { entry in
                            appRow(entry, largest: largest)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Spacing.lg)
                }
            }
        }
    }

    private func appRow(_ entry: AppFootprint, largest: Int64) -> some View {
        let isSelected = selectedAppID == entry.app.id
        return Button { selectedAppID = entry.app.id } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.app.url.path))
                    .resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(entry.app.name).font(Theme.Font.bodyStrong).lineLimit(1)
                        Spacer(minLength: Theme.Spacing.sm)
                        Text(entry.totalBytes.formattedBytes)
                            .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Meter(fraction: Double(entry.totalBytes) / Double(max(largest, 1)), height: 3)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.accent.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selected {
            let hasCaches = entry.paths.contains { $0.bucket == .caches }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    HStack(spacing: Theme.Spacing.lg) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.app.url.path))
                            .resizable().frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(entry.app.name).font(Theme.Font.title)
                            Text("\(entry.totalBytes.formattedBytes) in total  ·  app \(entry.app.sizeBytes.formattedBytes)  ·  data \(entry.libraryBytes.formattedBytes)")
                                .font(Theme.Font.body).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Trash Caches…") {
                            let caches = entry.paths.filter { $0.bucket == .caches }
                            sheetPlan = DeletionPlan(items: caches.map { ScanItem(url: $0.url, sizeBytes: $0.sizeBytes, isDirectory: true) })
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasCaches)
                        .help("Keeps the app installed. Caches rebuild on next launch.")
                    }
                    SurfaceSection("By kind") {
                        ForEach(Array(entry.bucketTotals.enumerated()), id: \.offset) { i, pair in
                            if i > 0 { RowDivider() }
                            HStack {
                                Text(pair.0.displayName).font(Theme.Font.body)
                                Spacer()
                                Meter(fraction: Double(pair.1) / Double(max(entry.libraryBytes, 1)),
                                      tint: pair.0 == .caches ? Theme.accent : Theme.used)
                                    .frame(width: 120)
                                Text(pair.1.formattedBytes)
                                    .font(Theme.Font.body.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.md)
                        }
                    }
                    SurfaceSection("Folders") {
                        ForEach(Array(entry.paths.enumerated()), id: \.element.id) { i, path in
                            if i > 0 { RowDivider() }
                            HStack(spacing: Theme.Spacing.md) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(path.url.lastPathComponent).font(Theme.Font.bodyStrong).lineLimit(1)
                                    Text(path.url.path)
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                Spacer()
                                Text(path.sizeBytes.formattedBytes)
                                    .font(Theme.Font.body.monospacedDigit()).foregroundStyle(.secondary)
                                Button { showInFinder(path.url) } label: {
                                    Image(systemName: "arrow.up.forward.square").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.borderless).help("Show in Finder")
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.md)
                        }
                    }
                }
                .padding(Theme.gutter)
            }
        } else {
            EmptyStateView(symbol: "square.stack.3d.up", title: "Choose an app",
                           message: "See where an app keeps its data, and clear its caches without uninstalling it.")
                .frame(maxHeight: .infinity)
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
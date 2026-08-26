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
            appList.frame(minWidth: 300, idealWidth: 340)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if attributions.isEmpty { await load() } }
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
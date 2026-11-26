import SwiftUI
import CoreKit

/// "What Changed?": what grew between two dated scans and what came back
/// after a cleanup, each with a jump into Disk Map. Read-only; every number
/// comes from scan history, the cleanup log and the current scan.
struct WhatChangedView: View {
    @Environment(AppState.self) private var state
    @AppStorage("MacTidy.whatChangedWindow") private var windowDays = WhatChanged.Window.month.rawValue

    private var window: WhatChanged.Window { WhatChanged.Window(rawValue: windowDays) ?? .month }

    var body: some View {
        let report = WhatChanged.make(history: state.scanHistory, cleanups: state.cleanupHistory,
                                      items: state.categoryResults.flatMap(\.items), window: window)
        Page("What Changed", subtitle: subtitle(report)) {
            Picker("Period", selection: $windowDays) {
                ForEach(WhatChanged.Window.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
        } content: {
            growthSection(report)
            returnedSection(report)
            scansSection(report)
        }
    }

    private func subtitle(_ report: WhatChanged) -> String {
        guard let latest = report.latest, let base = report.comparedWith else {
            return "Compares your scans over time. Scan on different days to see what grows."
        }
        var text = "Scan of \(latest.formatted(date: .abbreviated, time: .shortened)) compared with \(base.formatted(date: .abbreviated, time: .shortened))."
        if let delta = report.reclaimableDelta, delta != 0 {
            text += " Cleanable space \(delta > 0 ? "rose" : "fell") by \(abs(delta).formattedBytes)."
        }
        return text
    }

    // MARK: - Growth

    @ViewBuilder
    private func growthSection(_ report: WhatChanged) -> some View {
        switch report.growth {
        case .noHistory:
            SurfaceSection("Grew") {
                EmptyStateView(symbol: "chart.line.uptrend.xyaxis", title: "Nothing to compare yet",
                               message: "MacTidy needs two scans at least a day apart. A scan-only schedule in Settings keeps this up to date without deleting anything.")
                    .frame(maxWidth: .infinity)
            }
        case .steady:
            SurfaceSection("Grew") {
                Text("Nothing grew by 100 MB or more in this period.")
                    .font(Theme.Font.body).foregroundStyle(.secondary)
                    .padding(Theme.Spacing.lg)
            }
        case .growing(let nudges):
            SurfaceSection("Grew", footer: "Folders and categories that grew by at least 100 MB and 5%. Disk Map opens the folder in the current scan.") {
                ForEach(Array(nudges.enumerated()), id: \.element.id) { index, nudge in
                    if index > 0 { RowDivider(inset: 48) }
                    growthRow(nudge)
                }
            }
        }
    }

    private func growthRow(_ nudge: GrowthNudge) -> some View {
        let folder = ChangeLocator.folder(for: nudge, results: state.categoryResults, elsewhere: state.elsewhereItems)
        return HStack(spacing: Theme.Spacing.md) {
            Image(systemName: nudge.symbol)
                .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(nudge.name).font(Theme.Font.bodyStrong)
                Text("+\(nudge.delta.formattedBytes), now \(nudge.current.formattedBytes)")
                    .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if let folder {
                Button("Disk Map") { state.openInDiskMap(folder) }
                    .help(folder.path)
            }
            Button("Review") { review(nudge.place) }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func review(_ place: GrowthNudge.Place) {
        state.section = .cleanup
        switch place {
        case .category(let category):
            state.showingElsewhere = false
            state.drilledCategory = category
        case .handledElsewhere:
            state.drilledCategory = nil
            state.showingElsewhere = true
        }
    }

    // MARK: - Returned

    @ViewBuilder
    private func returnedSection(_ report: WhatChanged) -> some View {
        if !report.returned.isEmpty {
            SurfaceSection("Returned after cleanup", footer: "Cleaned in this period and present again. They may have rebuilt or been restored; cleaning again may not help.") {
                ForEach(Array(report.returned.prefix(20).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider(inset: 48) }
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: item.category?.symbol ?? "folder")
                            .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent).font(Theme.Font.bodyStrong)
                            Text(item.url.deletingLastPathComponent().path.abbreviatingWithTildeInPath)
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(item.sizeBytes.formattedBytes)
                            .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button("Disk Map") { state.openInDiskMap(ChangeLocator.folder(for: item)) }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                }
            }
        }
    }

    // MARK: - Scans

    @ViewBuilder
    private func scansSection(_ report: WhatChanged) -> some View {
        if !report.scans.isEmpty {
            SurfaceSection("Scans in this period") {
                ForEach(Array(report.scans.prefix(30).enumerated()), id: \.element.id) { index, scan in
                    if index > 0 { RowDivider() }
                    HStack {
                        Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                        if scan.date == report.comparedWith {
                            Badge(text: "Compared with", tint: .secondary)
                        }
                        Spacer()
                        Text("\(scan.reclaimableBytes.formattedBytes) cleanable")
                            .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.sm)
                }
            }
        }
    }
}

private extension String {
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}

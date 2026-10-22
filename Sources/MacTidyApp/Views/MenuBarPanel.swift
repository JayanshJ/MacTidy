import SwiftUI
import CoreKit

/// The menu bar popover: an at-a-glance reclaimable summary plus one-click
/// access to the app. Lives in a `MenuBarExtra` so MacTidy stays present even
/// with the main window closed.
///
/// Branding matches the main app: the real `AppIcon` from the bundle, the
/// teal `Theme.accent`, and a card surface — the same treatment the Welcome
/// hero and Dashboard header use. The headline number is the **full scan**
/// total (`state.totalReclaimable`, every category) when a real scan has run,
/// so the panel agrees with the dashboard; when there's no full scan yet it
/// falls back to the space monitor's quick-check total (the 5 fast
/// categories), clearly labeled "quick check" so it never overstates.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var diskPressure: DiskPressure?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            summary
            freeSpaceRow
            if !topCategories.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm + 2) {
                    let largest = topCategories.first?.totalBytes ?? 1
                    ForEach(topCategories) { result in
                        categoryRow(result, largest: largest)
                    }
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            actions
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 300)
        .tint(Theme.accent)
        .task {
            state.monitor.start()
            await refreshDiskPressure()
            // Keep the free-space ticker live while the popover is open —
            // a user who empties Trash or frees space in another app should
            // see the number update without reopening the panel. 30s cadence
            // is cheap (one volume attribute probe) and smooth.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await refreshDiskPressure()
            }
        }
    }

    /// Re-probes the boot volume's free bytes off the main actor and republishes
    /// `diskPressure`. Called on appear, on a 30s loop while the popover is
    /// open, and after "Quick check now" so the free-space line stays live
    /// (the original loaded it once and went stale for the life of the view).
    private func refreshDiskPressure() async {
        let pressure = await Task.detached { DiskPressure.current() }.value
        diskPressure = pressure
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            appIcon
            VStack(alignment: .leading, spacing: 1) {
                Text("MacTidy").font(Theme.Font.bodyStrong)
                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// The real app icon, rendered from the bundle's `AppIcon` asset so the
    /// menu bar panel matches the dock icon and the Welcome hero exactly.
    /// Falls back to a teal disk glyph when running as a bare SwiftPM binary
    /// without a bundle (the same fallback the Welcome view uses).
    private var appIcon: some View {
        Group {
            if let nsImage = NSImage(named: "AppIcon") ?? bundledAppIcon {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "internaldrive")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var bundledAppIcon: NSImage? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: "AppIcon", withExtension: "icns")
            ?? bundle.url(forResource: "AppIcon", withExtension: "png")
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Shows the quick-check recency (the monitor's own "last checked" time)
    /// so the user can tell how stale the quick-check number is. Hidden when
    /// we're showing a full-scan total instead.
    private var headerSubtitle: String? {
        guard !hasFullScan else { return nil }
        guard let checked = state.monitor.lastChecked else {
            return state.monitor.isChecking ? "checking…" : nil
        }
        let style = Date.RelativeFormatStyle(
            presentation: .named,
            capitalizationContext: .beginningOfSentence
        )
        return checked.formatted(style) + (state.monitor.isChecking ? " · checking…" : "")
    }

    // MARK: - Summary

    /// True when a real full scan has run (in this session or restored from a
    /// previous one). When this is true the headline shows `totalReclaimable`
    /// — the same number the Dashboard header shows — so the panel and the
    /// app agree. Otherwise the panel shows the quick-check total.
    private var hasFullScan: Bool { !state.categoryResults.isEmpty }

    /// The headline reclaimable number: the full-scan total when available,
    /// else the quick-check total.
    private var headlineBytes: Int64 {
        hasFullScan ? state.totalReclaimable : state.monitor.reclaimableBytes
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headlineBytes.formattedBytes)
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
                .foregroundStyle(headlineBytes > 0 ? Color.primary : Color.secondary)
            Text(hasFullScan ? "can be cleaned" : "can be cleaned, from a quick check")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A live free-space ticker from `DiskPressure.current()` — the actual
    /// free bytes on the boot volume, so the panel shows both "what you could
    /// reclaim" and "what's free now" in the same branded surface.
    @ViewBuilder
    private var freeSpaceRow: some View {
        if let pressure = diskPressure, pressure.isAvailable {
            VStack(alignment: .leading, spacing: 6) {
                CapacityBar(total: pressure.totalBytes, free: pressure.freeBytes,
                            cleanable: headlineBytes, height: 6)
                HStack {
                    Text("\(pressure.freeBytes.formattedBytes) free")
                    Spacer()
                    Text("\(Int(pressure.usedFraction * 100))% used")
                }
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Category breakdown

    /// Top reclaimable categories to list under the headline. Mirrors the
    /// dashboard: full-scan categories when a scan has run, otherwise the
    /// monitor's quick-check results. Sorted by size, capped at 4.
    private var topCategories: [CategoryResult] {
        let source = hasFullScan ? state.categoryResults : state.monitor.latestResults
        return source
            .filter { $0.totalBytes > 0 }
            .sorted { $0.totalBytes > $1.totalBytes }
            .prefix(4)
            .map { $0 }
    }

    private func categoryRow(_ result: CategoryResult, largest: Int64) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: result.category.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(result.category.displayName)
                .font(Theme.Font.body)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.sm)
            Text(result.totalBytes.formattedBytes)
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open MacTidy", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                Task {
                    await state.monitor.checkNow()
                    // A quick check may have freed context (or the user just
                    // trashed in the main window); refresh the free-space
                    // ticker too so the panel reflects the new reality.
                    await refreshDiskPressure()
                }
            } label: {
                if state.monitor.isChecking {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking…") }
                } else {
                    Label("Quick check now", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .font(Theme.Font.caption)
            .disabled(state.monitor.isChecking || !state.fdaGranted)
            .frame(maxWidth: .infinity)
        }
    }
}
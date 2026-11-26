import Foundation

/// The "What Changed?" page: what grew between two dated scans, and what came
/// back after a cleanup. Pure; built from scan history, the cleanup log and
/// the current scan. Reuses `ScanHistory.growthReport`, so a folder missing
/// from the earlier scan still means "not measured", never "grew from zero".
public struct WhatChanged: Sendable {
    public enum Window: Int, CaseIterable, Identifiable, Sendable {
        case week = 7, month = 30, quarter = 90
        public var id: Int { rawValue }
        public var days: Int { rawValue }
        public var displayName: String {
            switch self {
            case .week: "Week"
            case .month: "Month"
            case .quarter: "3 months"
            }
        }
    }

    /// Growth since `comparedWith`, with lower thresholds than the Overview.
    public let growth: GrowthReport
    /// The latest scan and the one it is compared with, or nil with no history.
    public let latest: Date?
    public let comparedWith: Date?
    /// Change in reclaimable bytes between the two scans (negative = less).
    public let reclaimableDelta: Int64?
    /// Items cleaned within the window that are present again.
    public let returned: [ScanItem]
    /// Every scan in the window, newest first.
    public let scans: [ScanSnapshot]

    public static func make(history: [ScanSnapshot], cleanups: [CleanupEntry], items: [ScanItem],
                            window: Window, now: Date = Date()) -> WhatChanged {
        let span = TimeInterval(window.days) * 86_400
        // `comparison` falls back to an older scan when none is in the window;
        // that would not be "this period", so say there is nothing to compare.
        let pair = ScanHistory.comparison(in: history, window: span)
            .flatMap { $0.latest.date.timeIntervalSince($0.base.date) <= span ? $0 : nil }
        let growth: GrowthReport = pair == nil ? .noHistory
            : ScanHistory.growthReport(in: history, minimumDelta: 100_000_000, minimumShare: 0.05,
                                       window: span, limit: 15)
        let scans = history.filter { now.timeIntervalSince($0.date) <= span }.sorted { $0.date > $1.date }
        return WhatChanged(
            growth: growth,
            latest: pair?.latest.date,
            comparedWith: pair?.base.date,
            reclaimableDelta: pair.map { $0.latest.reclaimableBytes - $0.base.reclaimableBytes },
            returned: RecurringCleanup.returned(items: items, history: cleanups, now: now, within: span),
            scans: scans
        )
    }
}

/// Finds the folder to open in Disk Map for something the user is looking at.
public enum ChangeLocator {
    /// The folder holding what a growth nudge measured, from the current scan:
    /// the deepest folder containing every matching item. Nil when nothing in
    /// the current scan matches or the items only share `/`, `/Users` or home.
    public static func folder(for nudge: GrowthNudge, results: [CategoryResult], elsewhere: [ScanItem],
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let items: [ScanItem]
        switch nudge.place {
        case .handledElsewhere:
            items = elsewhere.filter { $0.finding == nudge.folder }
        case .category(let category):
            let all = results.first { $0.category == category }?.items ?? []
            items = nudge.folder.map { owner in all.filter { $0.detail == owner } } ?? all
        }
        // Home itself is where Disk Map already starts; no help.
        guard let folder = commonFolder(of: items),
              folder.standardizedFileURL.path != home.standardizedFileURL.path else { return nil }
        return folder
    }

    /// The folder to open for one item: itself when a folder, else its parent.
    public static func folder(for item: ScanItem) -> URL {
        item.isDirectory ? item.url : item.url.deletingLastPathComponent()
    }

    public static func commonFolder(of items: [ScanItem]) -> URL? {
        guard let first = items.first else { return nil }
        if items.count == 1 { return folder(for: first) }
        var prefix = folder(for: first).standardizedFileURL.pathComponents
        for item in items.dropFirst() {
            let components = folder(for: item).standardizedFileURL.pathComponents
            prefix = Array(zip(prefix, components).prefix { $0 == $1 }.map(\.0))
        }
        // ["/", "Users"] or shorter says nothing useful.
        guard prefix.count > 2 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: prefix), isDirectory: true)
    }
}

/// The Overview's opt-out nudge for installers left in Downloads and Desktop
/// past the user's cutoff. Derived from the `.oldInstallers` results only; no
/// extra scanning, and it leads to that category rather than trashing.
public enum DownloadsHygiene {
    public struct Nudge: Sendable, Equatable {
        public let count: Int
        public let bytes: Int64
    }

    public static func nudge(results: [CategoryResult], minimumBytes: Int64 = 0) -> Nudge? {
        let items = results.first { $0.category == .oldInstallers }?.items ?? []
        let bytes = items.reduce(0) { $0 + $1.sizeBytes }
        guard !items.isEmpty, bytes >= minimumBytes else { return nil }
        return Nudge(count: items.count, bytes: bytes)
    }
}

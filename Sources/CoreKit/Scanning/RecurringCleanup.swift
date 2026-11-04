import Foundation

public enum RecurringCleanup {
    /// A restored item is not evidence of regrowth; the message says "returned".
    public static func returned(items: [ScanItem], history: [CleanupEntry], now: Date = Date()) -> [ScanItem] {
        let recentPaths = Set(history.filter {
            $0.kind == .deletion && now.timeIntervalSince($0.date) >= 0
                && now.timeIntervalSince($0.date) <= 7 * 86400
        }.flatMap { $0.paths ?? [] })
        return items.filter { $0.sizeBytes >= 100 * 1024 * 1024 && recentPaths.contains($0.url.standardizedFileURL.path) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    public static func isRecentBuild(_ item: ScanItem, now: Date = Date()) -> Bool {
        guard CategoryScanner.devRootsCategories.contains(item.category ?? .bigFiles),
              let modified = item.lastModified else { return false }
        return now.timeIntervalSince(modified) < 7 * 86400
    }
}

import Foundation

/// One ranked cleanup suggestion produced from scan results. Pure data —
/// `Recommendations` builds the ranking, the view turns it into a plan.
public struct Recommendation: Identifiable, Sendable, Hashable {
    /// Why this item was suggested — surfaced in the UI so the ranking is
    /// transparent, not a black box.
    public enum Reason: String, Sendable, Hashable {
        case safeCache
        case staleInstaller
        case staleBackup
        case staleBuildDir
        case bigFile
    }

    public let id: UUID
    public let item: ScanItem
    public let reason: Reason
    /// Higher = more worth doing. Bytes dominate; staleness and safety adjust.
    public let score: Double

    public init(item: ScanItem, reason: Reason, score: Double) {
        self.id = UUID()
        self.item = item
        self.reason = reason
        self.score = score
    }
}

/// Ranks scanned items into a curated cleanup plan. Lives in CoreKit so the
/// ranking is unit-testable and UI-free, consistent with the layering rule.
///
/// The ranking is intentionally transparent and byte-weighted: the biggest
/// wins come from large reclaimable size, then adjusted by how safe the item
/// is to trash (preselectable categories rank above suggest-only) and how
/// stale it is (older = less likely to be in active use). Suggest-only items
/// are still listed but never auto-selected.
public enum Recommendations {
    /// Builds the ranked list from category results. `limit` caps the count
    /// so the view stays scannable.
    public static func ranked(from results: [CategoryResult], limit: Int = 50) -> [Recommendation] {
        var recs: [Recommendation] = []
        for result in results {
            for item in result.items {
                guard let reason = reason(for: item, in: result.category) else { continue }
                let score = score(for: item, category: result.category, reason: reason)
                recs.append(Recommendation(item: item, reason: reason, score: score))
            }
        }
        return recs.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// The set of item IDs that are safe to auto-select — only items from
    /// preselectable categories. Suggest-only items are surfaced but require
    /// the user to opt in.
    public static func autoSelectableIDs(from recs: [Recommendation]) -> Set<UUID> {
        Set(recs.filter { $0.item.category?.isPreselectable == true }.map { $0.item.id })
    }

    private static func reason(for item: ScanItem, in category: Category) -> Recommendation.Reason? {
        switch category {
        case .xcodeDerivedData, .xcodeDeviceSupport, .simulatorCaches,
             .simulatorRuntimes, .userCaches, .homebrewCache, .devCaches:
            .safeCache
        case .oldInstallers: .staleInstaller
        case .iosBackups: .staleBackup
        case .nodeModules, .rustTargets: .staleBuildDir
        case .appSupport: nil   // real app state — never recommended, only listed
        case .bigFiles: .bigFile
        }
    }

    /// Score = bytes (the dominant factor) × safety multiplier × staleness
    /// multiplier. Multipliers are small adjustments, notOverrides — a 10 GB
    /// suggest-only file still outranks a 50 MB safe cache.
    private static func score(
        for item: ScanItem, category: Category, reason: Recommendation.Reason
    ) -> Double {
        let bytes = Double(item.sizeBytes)
        let safety = category.isPreselectable ? 1.0 : 0.5
        let staleness = stalenessMultiplier(item: item, reason: reason)
        return bytes * safety * staleness
    }

    private static func stalenessMultiplier(
        item: ScanItem, reason: Recommendation.Reason
    ) -> Double {
        guard let modified = item.lastModified else { return 1.0 }
        let daysOld = Date.now.timeIntervalSince(modified) / 86400
        // 0 days old → 0.5 (probably in use), 180+ days old → 1.0 (clearly stale).
        let factor = min(1.0, 0.5 + daysOld / 360)
        // Backups and installers carry their own age gate already; their
        // staleness is the whole point, so weight it harder.
        switch reason {
        case .staleInstaller, .staleBackup: return 0.6 + factor * 0.6
        default: return factor
        }
    }
}
import Foundation

/// Something that grew a lot since an earlier scan.
public struct GrowthNudge: Identifiable, Sendable, Equatable {
    /// Where the user can act on it.
    public enum Place: Sendable, Equatable {
        case category(Category)
        case handledElsewhere
    }

    public let name: String
    public let place: Place
    public let delta: Int64
    public let current: Int64
    public let since: Date
    public var id: String { name }

    /// "Claude grew 10 GB since last week"
    public func sentence(now: Date = Date()) -> String {
        "\(name) grew \(delta.formattedBytes) \(Self.period(since: since, now: now))"
    }

    static func period(since: Date, now: Date) -> String {
        let days = Int(now.timeIntervalSince(since) / 86_400)
        return switch days {
        case ..<2: "since yesterday"
        case 2...6: "in the last \(days) days"
        case 7...13: "since last week"
        case 14...27: "in the last \(days / 7) weeks"
        case 28...59: "since last month"
        default: "in the last \(days / 30) months"
        }
    }
}

/// What the Overview can say about growth.
public enum GrowthReport: Sendable, Equatable {
    /// No scan old enough to compare with.
    case noHistory
    /// Compared with an earlier scan; nothing grew by enough to mention.
    case steady
    case growing([GrowthNudge])
}

extension ScanHistory {
    private static let appSupportPrefix = "appSupport:"
    private static let elsewherePrefix = "elsewhere:"

    /// The folder-level totals a snapshot keeps, beyond categories: each app in
    /// Application Support (that category is too broad to name the culprit) and
    /// each handled-elsewhere rule (those bytes are in no category).
    ///
    /// Every rule this scan could read gets a key, even at zero, so a key
    /// missing from an older snapshot means "not measured then": bytes that
    /// appear once Full Disk Access is granted aren't mistaken for growth.
    public static func folderTotals(results: [CategoryResult], elsewhere: [ScanItem],
                                    fullDiskAccess: Bool) -> [String: Int64] {
        var totals: [String: Int64] = [:]
        for item in results.first(where: { $0.category == .appSupport })?.items ?? [] {
            // A removed app's folder only appears once it has aged a month.
            guard let owner = item.detail, owner != AppSupportRules.removedAppsGroup else { continue }
            totals[appSupportPrefix + owner, default: 0] += item.sizeBytes
        }
        for rule in HandledElsewhere.rules where fullDiskAccess || !rule.needsFullDiskAccess {
            totals[elsewherePrefix + rule.id] = 0
        }
        for item in elsewhere {
            guard let id = item.finding else { continue }
            totals[elsewherePrefix + id, default: 0] += item.sizeBytes
        }
        return totals
    }

    /// The Overview's growth insight. Pure and deterministic.
    ///
    /// Compares the latest scan with the oldest one from the past `window`
    /// (so slow steady growth still adds up), or, if there is none, the newest
    /// older scan. A nudge needs at least `minimumDelta` and `minimumShare` of
    /// what was there before: 1 GB matters to a 2 GB folder, not to a 200 GB
    /// game library. Biggest first, at most `limit`.
    public static func growthReport(in history: [ScanSnapshot],
                                    minimumDelta: Int64 = 1_000_000_000,
                                    minimumShare: Double = 0.1,
                                    minimumGap: TimeInterval = 20 * 3600,
                                    window: TimeInterval = 8 * 86_400,
                                    limit: Int = 3) -> GrowthReport {
        let tracked = history.filter { $0.categories != nil }.sorted { $0.date > $1.date }
        guard let latest = tracked.first, let now = latest.categories else { return .noHistory }
        let older = tracked.filter { latest.date.timeIntervalSince($0.date) >= minimumGap }
        let recent = older.filter { latest.date.timeIntervalSince($0.date) <= window }
        guard let base = recent.last ?? older.first, let before = base.categories else { return .noHistory }

        var nudges: [GrowthNudge] = []
        func consider(_ name: String, _ place: GrowthNudge.Place, current: Int64, baseline: Int64) {
            let delta = current - baseline
            guard delta >= minimumDelta, Double(delta) >= minimumShare * Double(baseline) else { return }
            nudges.append(GrowthNudge(name: name, place: place, delta: delta, current: current, since: base.date))
        }

        // Application Support is named app by app when both scans can.
        let folders = latest.folders.flatMap { now in base.folders.map { (now: now, before: $0) } }
        for (key, bytes) in now {
            // A category an older version didn't know wasn't measured then.
            guard let category = Category(rawValue: key), let baseline = before[key] else { continue }
            if category == .appSupport, folders != nil { continue }
            consider(category.displayName, .category(category), current: bytes, baseline: baseline)
        }
        for (key, bytes) in folders?.now ?? [:] {
            if key.hasPrefix(appSupportPrefix) {
                consider(String(key.dropFirst(appSupportPrefix.count)), .category(.appSupport),
                         current: bytes, baseline: folders?.before[key] ?? 0)
            } else if key.hasPrefix(elsewherePrefix),
                      let rule = HandledElsewhere.rule(id: String(key.dropFirst(elsewherePrefix.count))),
                      let baseline = folders?.before[key] {
                consider(rule.label, .handledElsewhere, current: bytes, baseline: baseline)
            }
        }
        guard !nudges.isEmpty else { return .steady }
        return .growing(Array(nudges.sorted { ($0.delta, $1.name) > ($1.delta, $0.name) }.prefix(limit)))
    }
}

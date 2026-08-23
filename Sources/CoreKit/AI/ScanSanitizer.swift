import Foundation

/// The privacy boundary between MacTidy and a cloud model. Converts scan
/// results into a compact JSON payload the model can reason over, sending
/// only **labels + counts + sizes + staleness** by default. File paths/names
/// are included only when `AIConfig.sendFilePaths` is true (an explicit opt-in
/// the user sets in Settings; off by default). Ollama is local, so this is a
/// privacy concern only for cloud providers — but the sanitizer is applied
/// uniformly so the contract is the same regardless of provider.
public enum ScanSanitizer {
    /// One category, reduced to the minimal description the model needs.
    public struct CategorySummary: Codable, Sendable {
        public let category: String
        public let itemCount: Int
        public let totalBytes: Int64
        /// "2024-03-12" of the oldest item, or nil — how stale the data is.
        public let oldestModified: String?
        /// Whether the category is safe to bulk-trash (preselectable).
        public let safeToBulkDelete: Bool
        /// Item details: paths only when sendFilePaths is on; otherwise just
        /// sizes and (for big files) a generic kind hint.
        public let items: [ItemSummary]
    }

    public struct ItemSummary: Codable, Sendable {
        public let index: Int
        public let bytes: Int64
        /// Path or name — only present when the privacy toggle is on.
        public let path: String?
        /// Context like "in ~/Developer/foo" — only when paths are allowed.
        public let detail: String?
        public let modified: String?
    }

    /// Builds the sanitized summary array. `id` is included so the caller can
    /// map the model's selection back to real `ScanItem`s without sending
    /// their paths — the index into each category's `items` array is the join
    /// key.
    public static func summarize(
        _ categories: [CategoryResult],
        sendFilePaths: Bool
    ) -> [CategorySummary] {
        categories.map { result in
            CategorySummary(
                category: result.category.displayName,
                itemCount: result.items.count,
                totalBytes: result.totalBytes,
                oldestModified: result.items
                    .compactMap(\.lastModified)
                    .map { ISO8601DateFormatter().string(from: $0) }
                    .min(),
                safeToBulkDelete: result.category.isPreselectable,
                items: result.items.enumerated().map { idx, item in
                    ItemSummary(
                        index: idx,
                        bytes: item.sizeBytes,
                        path: sendFilePaths ? item.url.lastPathComponent : nil,
                        detail: sendFilePaths ? item.detail : nil,
                        modified: item.lastModified
                            .map { ISO8601DateFormatter().string(from: $0) }
                    )
                }
            )
        }
    }

    /// Renders the sanitized summary as the JSON string sent to the model.
    public static func payload(
        _ categories: [CategoryResult],
        sendFilePaths: Bool
    ) throws -> String {
        let data = try JSONEncoder().encode(summarize(categories, sendFilePaths: sendFilePaths))
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Resolves the model's selection (category display names + item indices)
    /// back to the real `ScanItem`s from the original scan. Only items that
    /// actually exist in the scan are returned — a hallucinated index or
    /// category name yields nothing, so the model can't select a path that
    /// wasn't already surfaced by the (read-only) scanner.
    public static func resolve(
        selection: [(category: String, indices: [Int])],
        in categories: [CategoryResult]
    ) -> [ScanItem] {
        var picked: [ScanItem] = []
        for (name, indices) in selection {
            guard let result = categories.first(where: { $0.category.displayName == name }) else {
                continue
            }
            for idx in indices where idx >= 0 && idx < result.items.count {
                picked.append(result.items[idx])
            }
        }
        return picked
    }
}
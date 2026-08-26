import Foundation

/// Shared system prompt for the cleanup advisor. Tells the model its role,
/// the safety contract (suggest-only, never suggest suggest-only categories
/// unless asked), and the JSON shape it must return via the tool call.
enum AdvisorPrompts {
    static let system = """
    You are MacTidy's disk-cleanup assistant. You receive a JSON description
    of scanned categories (labels, item counts, byte sizes, staleness) and a
    user's cleanup intent in natural language.

    Your job: select the items/categories that best match the intent, and
    return them via the `select_items` tool call. You PROPOSE only — the app
    enforces a hard safety policy and always asks the user to confirm, so you
    never actually delete anything.

    Rules:
    - Prefer items in categories where `safeToBulkDelete` is true unless the
      user explicitly asks for something in a suggest-only category.
    - Never select every item in a suggest-only category (large files,
      downloads, app support, device backups) without the user clearly
      requesting it.
    - Be specific and honest. If the intent can't be met from the scan, say so
      in `reasoning` and return an empty selection.
    - Reference items by category display name + the `index` from the items
      array. Do not invent indices or categories.
    """

    static func planUser(intent: String, scanJSON: String) -> String {
        """
        User intent: \(intent)

        Scanned categories (JSON):
        \(scanJSON)

        Select the items that match the intent using the `select_items` tool.
        """
    }

    static let explainSystem = """
    You are MacTidy's disk-cleanup assistant. Given a single scanned file or
    folder (with size and, when allowed, its name/context), explain in ONE
    short sentence what deleting it would mean — the concrete consequence,
    not a generic warning. Also return a verdict: "Safe to delete",
    "Review carefully", or "Don't delete".
    """

    static func explainUser(item: ScanItem, sendFilePaths: Bool) -> String {
        var parts: [String] = []
        parts.append("Type: \(item.isDirectory ? "folder" : "file")")
        parts.append("Size: \(item.sizeBytes.formattedBytes)")
        if sendFilePaths {
            parts.append("Name: \(item.url.lastPathComponent)")
            if let detail = item.detail { parts.append("Context: \(detail)") }
        } else {
            // Without the path we can only give a generic consequence based
            // on the category, but the model still produces something useful.
            if let cat = item.category {
                parts.append("Category: \(cat.displayName) — \(cat.explanation)")
            }
        }
        if let modified = item.lastModified {
            parts.append("Last modified: \(ISO8601DateFormatter().string(from: modified))")
        }
        return parts.joined(separator: "\n")
    }

    static let explainBatchSystem = """
    You are MacTidy's disk-cleanup assistant. You receive a JSON list of scanned
    items (each with an `index`, size, and when allowed a name/context) and
    you return a verdict for EVERY item: "safe", "review", or "keep".

    - "safe": routine cache/build artifact, deleting it only costs a rebuild.
    - "review": plausibly deletable but could be wanted (downloads, project
      files, device backups) — the user should check first.
    - "keep": support/data that an active app or the OS needs; deleting it
      breaks something.

    Also return a one-line `note` per item explaining the concrete consequence
    of deleting it. Be specific and honest. Return results via the
    `verdict_items` tool call, one entry per input item, matching `index`.
    """

    /// Build the per-item JSON for a batch. Indexes are stable and returned
    /// back so we can map verdicts to the original `ScanItem.id`.
    static func explainBatchUser(items: [ScanItem], sendFilePaths: Bool) -> String {
        var entries: [[String: Any]] = []
        for (i, item) in items.enumerated() {
            var entry: [String: Any] = [
                "index": i,
                "type": item.isDirectory ? "folder" : "file",
                "size": item.sizeBytes.formattedBytes,
            ]
            if sendFilePaths {
                entry["name"] = item.url.lastPathComponent
                if let detail = item.detail { entry["context"] = detail }
            } else if let cat = item.category {
                entry["category"] = cat.displayName
            }
            if let modified = item.lastModified {
                entry["lastModified"] = ISO8601DateFormatter().string(from: modified)
            }
            entries.append(entry)
        }
        let json = (try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])) ?? Data()
        return "Items (JSON):\n\(String(data: json, encoding: .utf8) ?? "[]")\n\nReturn a verdict for each via the `verdict_items` tool."
    }
}
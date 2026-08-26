import Foundation

/// Shared prompts + parsing for the proactive insights feature. The model
/// receives a sanitized snapshot (disk categories, memory totals, top
/// processes by RAM — no paths unless opted in) and returns a JSON array of
/// insights via the `propose_insights` tool call. We resolve its selections
/// back to real `ScanItem`s / process names, enforcing the denylist.
enum InsightPrompts {
    static let system = """
    You are MacTidy's proactive system advisor. You receive a JSON snapshot of
    the user's Mac: reclaimable disk categories (with byte sizes), system
    memory totals, the top running processes by resident RAM, boot-volume free
    space, and the list of login items. Your job is to surface 3–6 narrative
    insights that would actually help: where they can reclaim space, where idle
    apps are wasting RAM, what's worth leaving alone.

    Each insight is one short sentence a human would say, plus a proposed
    action via the `propose_insights` tool. Rules:
    - Be specific and honest. "Slack is holding 1.8GB and you last used it
      hours ago" beats "Some apps use memory."
    - Only suggest quitting a process if it is a user app (appBundlePath is
      present) AND cpuPercent is near 0. Never suggest quitting processes
      where appBundlePath is null — those are system daemons.
    - For disk, prefer safe-to-bulk categories (safeToBulkDelete true). Only
      surface suggest-only categories (large files, downloads, app support)
      when there's a clear, specific reason — and mark them "review".
    - When the boot volume is nearly full (low free space), frame the biggest
      safe reclaim as urgent and lead with it.
    - Login items: if there are many, surface a "startup is heavy" observe
      insight pointing the user at System Settings. Never propose an action to
      disable a login item — that's the user's call. Use the `observe` action.
    - When there's nothing worth doing, return an `observe` insight explaining
      why (e.g. "Docker is using 6GB but you ran a container today").
    - Reference disk categories by their displayName and item indices; apps
      by their name. Do not invent indices or names that aren't in the snapshot.
    - Prioritize by real value (bytes reclaimed × likelihood the user won't
      need it back soon).
    """

    static func userPayload(snapshot: SystemSnapshot, sendFilePaths: Bool) throws -> String {
        var parts: [String] = []

        // Disk: sanitized category summaries.
        let cats = try ScanSanitizer.payload(snapshot.categories, sendFilePaths: sendFilePaths)
        parts.append("Disk categories (JSON):\n\(cats)")

        // Memory.
        if let mem = snapshot.memory {
            parts.append("""
            Memory:
            - total: \(mem.totalBytes.formattedBytes)
            - used: \(mem.usedBytes.formattedBytes)
            - free (incl. inactive): \(mem.freeBytes.formattedBytes)
            - swap used: \(mem.swapUsedBytes.formattedBytes)
            """)
        }

        // Top processes by RAM — sanitized: name, RSS, CPU, and whether it's
        // a user app (has a bundle path). No paths unless opted in.
        let top = snapshot.processes
            .filter { $0.residentBytes > 50 * 1024 * 1024 }  // >50MB only
            .prefix(40)
        var procLines: [String] = []
        for p in top {
            var line = "- name: \(p.name), rss: \(p.residentBytes.formattedBytes), cpu: \(String(format: "%.1f", p.cpuPercent))%"
            line += p.appBundlePath != nil ? ", type: userApp" : ", type: system"
            if sendFilePaths, let path = p.appBundlePath { line += ", bundle: \(path)" }
            procLines.append(line)
        }
        parts.append("Top processes by RAM:\n" + procLines.joined(separator: "\n"))

        // Boot-volume pressure — drives "disk almost full" framing. Just the
        // totals + used fraction; no paths.
        if let pressure = snapshot.diskPressure, pressure.isAvailable {
            parts.append("""
            Boot volume:
            - total: \(pressure.totalBytes.formattedBytes)
            - free: \(pressure.freeBytes.formattedBytes)
            - used: \(Int(pressure.usedFraction * 100))%
            """)
        }

        // Login items — count +, when paths are allowed, their labels. Startup
        // insights are observe-only; the model should point, not act.
        if let items = snapshot.launchItems {
            var launchLines: [String] = ["- count: \(items.count)"]
            if sendFilePaths {
                for item in items.prefix(40) {
                    launchLines.append("- \(item.label)")
                }
            }
            parts.append("Login items:\n" + launchLines.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    static var tool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "propose_insights",
                "description": "Return proactive cleanup/memory insights for the user.",
                "parameters": [
                    "type": "object",
                    "properties": [
                    "insights": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "kind": ["type": "string", "enum": ["disk", "memory", "processes", "combo"]],
                                "reasoning": ["type": "string"],
                                "action": ["type": "string", "enum": ["trash", "quit", "observe"]],
                                // For trash: array of {category, indices}.
                                "trashSelection": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "category": ["type": "string"],
                                            "indices": ["type": "array", "items": ["type": "integer"]],
                                        ],
                                    ],
                                ],
                                // For quit: array of app names.
                                "quitApps": ["type": "array", "items": ["type": "string"]],
                                "reclaimableBytes": ["type": "integer"],
                                "priority": ["type": "integer"],
                            ],
                            "required": ["kind", "reasoning", "action", "priority"],
                        ],
                    ],
                ],
                "required": ["insights"],
            ],
        ],
        ]
    }

    /// Anthropic-flavored tool schema (input_schema instead of parameters).
    static var anthropicTool: [String: Any] {
        [
            "name": "propose_insights",
        "description": "Return proactive cleanup/memory insights for the user.",
        "input_schema": [
            "type": "object",
            "properties": [
                "insights": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "kind": ["type": "string", "enum": ["disk", "memory", "processes", "combo"]],
                            "reasoning": ["type": "string"],
                            "action": ["type": "string", "enum": ["trash", "quit", "observe"]],
                            "trashSelection": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "category": ["type": "string"],
                                        "indices": ["type": "array", "items": ["type": "integer"]],
                                    ],
                                ],
                            ],
                            "quitApps": ["type": "array", "items": ["type": "string"]],
                            "reclaimableBytes": ["type": "integer"],
                            "priority": ["type": "integer"],
                        ],
                        "required": ["kind", "reasoning", "action", "priority"],
                    ],
                ],
            ],
            "required": ["insights"],
        ],
        ]
    }
}

/// Resolves a raw insights tool-call payload (the parsed `insights` array)
/// into real `Insight` objects, enforcing the process denylist and mapping
/// disk selections back to actual `ScanItem`s from the snapshot.
public enum InsightResolver {
    public static func resolve(_ raw: [String: Any], snapshot: SystemSnapshot) -> [Insight] {
        guard let arr = raw["insights"] as? [[String: Any]] else { return [] }
        var results: [Insight] = []
        for entry in arr {
            guard let reasoning = entry["reasoning"] as? String,
                  let actionStr = entry["action"] as? String,
                  let kindStr = entry["kind"] as? String else { continue }
            let kind: Insight.Kind = {
                switch kindStr {
                case "memory": return .memory
                case "processes": return .processes
                case "combo": return .combo
                default: return .disk
                }
            }()
            let bytes = Int64(entry["reclaimableBytes"] as? Int ?? 0)
            let priority = entry["priority"] as? Int ?? 1

            switch actionStr {
            case "trash":
                let sel = parseSelection(entry["trashSelection"])
                let items = ScanSanitizer.resolve(selection: sel, in: snapshot.categories)
                guard !items.isEmpty else { continue }
                results.append(Insight(kind: kind, reasoning: reasoning,
                                       action: .trash(items: items),
                                       reclaimableBytes: bytes > 0 ? bytes : items.reduce(0) { $0 + $1.sizeBytes },
                                       priority: priority))
            case "quit":
                let names = (entry["quitApps"] as? [String]) ?? []
                // Enforce the denylist: never propose quitting a denied name,
                // and only allow names that are actually running user apps.
                let safe = names.filter { name in
                    !ProcessDenylist.isDenied(name)
                    && snapshot.processes.contains { $0.name == name && $0.appBundlePath != nil }
                }
                guard !safe.isEmpty else { continue }
                let ram = safe.flatMap { name in
                    snapshot.processes.filter { $0.name == name }
                }.reduce(0) { $0 + $1.residentBytes }
                results.append(Insight(kind: kind == .disk ? .processes : kind,
                                       reasoning: reasoning,
                                       action: .quitApps(names: safe),
                                       reclaimableBytes: bytes > 0 ? bytes : ram,
                                       priority: priority))
            default:  // observe
                results.append(Insight(kind: kind, reasoning: reasoning,
                                       action: .observe,
                                       reclaimableBytes: 0, priority: priority))
            }
        }
        return results.sorted { $0.priority > $1.priority }
    }

    private static func parseSelection(_ raw: Any?) -> [(category: String, indices: [Int])] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { entry in
            guard let cat = entry["category"] as? String else { return nil }
            let indices = (entry["indices"] as? [Int])
                ?? (entry["indices"] as? [Double]).map { $0.map(Int.init) } ?? []
            return (cat, indices)
        }
    }
}
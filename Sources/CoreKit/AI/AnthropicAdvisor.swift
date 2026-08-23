import Foundation

/// Advisor for Anthropic's Messages API with tool use. Returns a structured
/// `select_items` tool_use block. Same privacy contract: paths only when
/// `AIConfig.sendFilePaths` is on.
private let anthropicEndpoint = "https://api.anthropic.com/v1/messages"

struct AnthropicAdvisor: CleanAdvisor {
    let apiKey: String

    func plan(
        for intent: String,
        categories: [CategoryResult],
        config: AIConfig
    ) async throws -> AdvicePlan {
        let scanJSON = try ScanSanitizer.payload(categories, sendFilePaths: config.sendFilePaths)
        let body: [String: Any] = [
            "model": config.model.isEmpty ? AIProvider.anthropic.defaultModel : config.model,
            "max_tokens": 1024,
            "system": AdvisorPrompts.system,
            "messages": [
                ["role": "user", "content": AdvisorPrompts.planUser(intent: intent, scanJSON: scanJSON)],
            ],
            "tools": [selectItemsTool],
            "tool_choice": ["type": "tool", "name": "select_items"],
            "temperature": 0.2,
        ]
        let headers: [String: String] = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
        let resp = try await HTTPClient.post(url: anthropicEndpoint, headers: headers, body: body)
        return try parsePlan(from: resp, categories: categories)
    }

    func explain(_ item: ScanItem, config: AIConfig) async throws -> ItemExplanation {
        let body: [String: Any] = [
            "model": config.model.isEmpty ? AIProvider.anthropic.defaultModel : config.model,
            "max_tokens": 256,
            "system": AdvisorPrompts.explainSystem,
            "messages": [
                ["role": "user", "content": AdvisorPrompts.explainUser(item: item, sendFilePaths: config.sendFilePaths)],
            ],
            "temperature": 0.2,
        ]
        let headers: [String: String] = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
        let resp = try await HTTPClient.post(url: anthropicEndpoint, headers: headers, body: body)
        return try parseExplanation(from: resp)
    }

    func insights(for snapshot: SystemSnapshot, config: AIConfig) async throws -> [Insight] {
        let payload = try InsightPrompts.userPayload(snapshot: snapshot, sendFilePaths: config.sendFilePaths)
        let body: [String: Any] = [
            "model": config.model.isEmpty ? AIProvider.anthropic.defaultModel : config.model,
            "max_tokens": 1024,
            "system": InsightPrompts.system,
            "messages": [["role": "user", "content": payload]],
            "tools": [InsightPrompts.anthropicTool],
            "tool_choice": ["type": "tool", "name": "propose_insights"],
            "temperature": 0.3,
        ]
        let headers: [String: String] = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
        let resp = try await HTTPClient.post(url: anthropicEndpoint, headers: headers, body: body)
        return try parseInsights(from: resp, snapshot: snapshot)
    }

    func testConnection(config: AIConfig) async -> String {
        let body: [String: Any] = [
            "model": config.model.isEmpty ? AIProvider.anthropic.defaultModel : config.model,
            "max_tokens": 5,
            "messages": [["role": "user", "content": "Reply with the single word: ok"]],
            "temperature": 0,
        ]
        let headers: [String: String] = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
        do {
            let resp = try await HTTPClient.post(url: anthropicEndpoint, headers: headers, body: body, timeout: 10)
            if let text = extractText(from: resp) { return "Connected — model replied: \(text)" }
            return "Connected (status \(resp.statusCode))"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }

    private var selectItemsTool: [String: Any] {
        [
            "name": "select_items",
            "description": "Select scanned items to trash that match the user's cleanup intent.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "reasoning": ["type": "string", "description": "One short sentence explaining the selection."],
                    "selection": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "category": ["type": "string"],
                                "indices": ["type": "array", "items": ["type": "integer"]],
                            ],
                            "required": ["category", "indices"],
                        ],
                    ],
                ],
                "required": ["reasoning", "selection"],
            ],
        ]
    }

    private func parsePlan(from resp: HTTPClient.Response, categories: [CategoryResult]) throws -> AdvicePlan {
        guard let json = resp.json as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw HTTPClient.HTTPError.decoding("missing content blocks")
        }
        for block in content {
            if block["type"] as? String == "tool_use",
               let name = block["name"] as? String, name == "select_items",
               let input = block["input"] as? [String: Any] {
                let reasoning = input["reasoning"] as? String ?? ""
                let selection = parseSelection(input["selection"])
                let items = ScanSanitizer.resolve(selection: selection, in: categories)
                return AdvicePlan(reasoning: reasoning, items: items)
            }
        }
        // Fallback to a text block.
        if let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
            return AdvicePlan(reasoning: text, items: [])
        }
        throw HTTPClient.HTTPError.decoding("no tool_use or text block in response")
    }

    private func parseSelection(_ raw: Any?) -> [(category: String, indices: [Int])] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { entry in
            guard let cat = entry["category"] as? String else { return nil }
            let indices = (entry["indices"] as? [Int]) ?? []
            return (cat, indices)
        }
    }

    private func parseExplanation(from resp: HTTPClient.Response) throws -> ItemExplanation {
        guard let text = extractText(from: resp) else {
            throw HTTPClient.HTTPError.decoding("no text block in response")
        }
        let lower = text.lowercased()
        let verdict: ItemExplanation.Verdict? = {
            if lower.contains("don't delete") || lower.contains("do not delete") { return .keep }
            if lower.contains("review") || lower.contains("carefully") { return .review }
            if lower.contains("safe") { return .safe }
            return nil
        }()
        return ItemExplanation(summary: text, verdict: verdict)
    }

    private func parseInsights(from resp: HTTPClient.Response, snapshot: SystemSnapshot) throws -> [Insight] {
        guard let json = resp.json as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw HTTPClient.HTTPError.decoding("missing content blocks")
        }
        for block in content {
            if block["type"] as? String == "tool_use",
               let name = block["name"] as? String, name == "propose_insights",
               let input = block["input"] as? [String: Any] {
                return InsightResolver.resolve(input, snapshot: snapshot)
            }
        }
        return []
    }

    private func extractText(from resp: HTTPClient.Response) -> String? {
        guard let json = resp.json as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        return content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
    }
}
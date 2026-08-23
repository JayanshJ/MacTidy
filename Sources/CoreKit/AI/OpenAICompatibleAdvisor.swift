import Foundation

/// Advisor that speaks the OpenAI Chat Completions API with tool calls — used
/// for both OpenAI and Ollama (Ollama exposes an OpenAI-compatible
/// `/v1/chat/completions` endpoint at its base URL). The model returns a
/// structured `select_items` tool call, which we resolve back to real
/// `ScanItem`s via `ScanSanitizer.resolve`. The model never sees full paths
/// unless `AIConfig.sendFilePaths` is true.
struct OpenAICompatibleAdvisor: CleanAdvisor {
    let endpoint: String
    let apiKey: String?
    let model: String

    func plan(
        for intent: String,
        categories: [CategoryResult],
        config: AIConfig
    ) async throws -> AdvicePlan {
        let scanJSON = try ScanSanitizer.payload(categories, sendFilePaths: config.sendFilePaths)
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": AdvisorPrompts.system],
                ["role": "user", "content": AdvisorPrompts.planUser(intent: intent, scanJSON: scanJSON)],
            ],
            "tools": [selectItemsTool],
            "tool_choice": ["type": "function", "function": ["name": "select_items"]],
            "temperature": 0.2,
        ]
        let headers = authHeaders()
        let resp = try await HTTPClient.post(url: endpoint, headers: headers, body: body)
        return try parsePlan(from: resp, categories: categories)
    }

    func explain(_ item: ScanItem, config: AIConfig) async throws -> ItemExplanation {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": AdvisorPrompts.explainSystem],
                ["role": "user", "content": AdvisorPrompts.explainUser(item: item, sendFilePaths: config.sendFilePaths)],
            ],
            "temperature": 0.2,
        ]
        let resp = try await HTTPClient.post(url: endpoint, headers: authHeaders(), body: body)
        return try parseExplanation(from: resp)
    }

    func insights(for snapshot: SystemSnapshot, config: AIConfig) async throws -> [Insight] {
        let payload = try InsightPrompts.userPayload(snapshot: snapshot, sendFilePaths: config.sendFilePaths)
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": InsightPrompts.system],
                ["role": "user", "content": payload],
            ],
            "tools": [InsightPrompts.tool],
            "tool_choice": ["type": "function", "function": ["name": "propose_insights"]],
            "temperature": 0.3,
        ]
        let resp = try await HTTPClient.post(url: endpoint, headers: authHeaders(), body: body)
        return try parseInsights(from: resp, snapshot: snapshot)
    }

    func testConnection(config: AIConfig) async -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Reply with the single word: ok"]],
            "max_tokens": 5,
            "temperature": 0,
        ]
        do {
            let resp = try await HTTPClient.post(url: endpoint, headers: authHeaders(), body: body, timeout: 10)
            if let content = extractContent(from: resp) {
                return "Connected — model replied: \(content)"
            }
            return "Connected (status \(resp.statusCode))"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Tool schema

    private var selectItemsTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "select_items",
                "description": "Select scanned items to trash that match the user's cleanup intent.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "reasoning": [
                            "type": "string",
                            "description": "One short sentence explaining why these items were selected.",
                        ],
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
            ],
        ]
    }

    // MARK: - Response parsing

    /// Extracts the `select_items` tool call from an OpenAI-format response
    /// and resolves it to real `ScanItem`s.
    private func parsePlan(from resp: HTTPClient.Response, categories: [CategoryResult]) throws -> AdvicePlan {
        guard let json = resp.json as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw HTTPClient.HTTPError.decoding("missing choices/message")
        }
        // Tool calls path.
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let call = toolCalls.first,
           let function = call["function"] as? [String: Any],
           let argsString = function["arguments"] as? String,
           let argsData = argsString.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            let reasoning = args["reasoning"] as? String ?? ""
            let selection = parseSelection(args["selection"])
            let items = ScanSanitizer.resolve(selection: selection, in: categories)
            return AdvicePlan(reasoning: reasoning, items: items)
        }
        // Fallback: some models put content as plain text.
        if let content = message["content"] as? String {
            return AdvicePlan(reasoning: content, items: [])
        }
        throw HTTPClient.HTTPError.decoding("no tool call or content in response")
    }

    private func parseSelection(_ raw: Any?) -> [(category: String, indices: [Int])] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { entry in
            guard let cat = entry["category"] as? String else { return nil }
            let indices = (entry["indices"] as? [Int]) ?? (entry["indices"] as? [Double]).map { $0.map(Int.init) } ?? []
            return (cat, indices)
        }
    }

    private func parseExplanation(from resp: HTTPClient.Response) throws -> ItemExplanation {
        guard let content = extractContent(from: resp) else {
            throw HTTPClient.HTTPError.decoding("no content in response")
        }
        // Try to pull a verdict line out of the response heuristically.
        let verdict: ItemExplanation.Verdict? = {
            let lower = content.lowercased()
            if lower.contains("don't delete") || lower.contains("do not delete") { return .keep }
            if lower.contains("review") || lower.contains("carefully") || lower.contains("check") { return .review }
            if lower.contains("safe") { return .safe }
            return nil
        }()
        return ItemExplanation(summary: content, verdict: verdict)
    }

    private func parseInsights(from resp: HTTPClient.Response, snapshot: SystemSnapshot) throws -> [Insight] {
        guard let json = resp.json as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw HTTPClient.HTTPError.decoding("missing choices/message")
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let call = toolCalls.first,
           let function = call["function"] as? [String: Any],
           let argsString = function["arguments"] as? String,
           let argsData = argsString.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            return InsightResolver.resolve(args, snapshot: snapshot)
        }
        return []
    }

    private func extractContent(from resp: HTTPClient.Response) -> String? {
        guard let json = resp.json as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    private func authHeaders() -> [String: String] {
        var h: [String: String] = [:]
        if let key = apiKey, !key.isEmpty {
            h["Authorization"] = "Bearer \(key)"
        }
        return h
    }
}
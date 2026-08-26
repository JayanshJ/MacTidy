import Foundation

/// Read-only detection of a running Ollama instance and the list of models
/// it has installed. Used by Settings to offer Ollama as a one-click fully-
/// local AI option — no credentials, nothing leaves the Mac. Returns nil
/// (or an empty list) when Ollama isn't running, so the UI never blocks.
public enum OllamaDetector {
    /// One installed Ollama model, as reported by `GET /api/tags`.
    public struct Model: Sendable, Hashable {
        public let name: String
        public init(name: String) { self.name = name }
    }

    /// The result of a detection probe: whether Ollama is reachable and the
    /// models it reports. `models` is empty when reachable but no models are
    /// installed (the user needs to `ollama pull` one).
    public struct Detection: Sendable {
        public let baseURL: String
        public let models: [Model]
        public var isReachable: Bool { !models.isEmpty || didRespond }
        /// True when Ollama responded at all (even with zero models).
        public let didRespond: Bool
        public init(baseURL: String, models: [Model], didRespond: Bool) {
            self.baseURL = baseURL
            self.models = models
            self.didRespond = didRespond
        }
    }

    /// Probe `baseURL/api/tags` (defaults to the standard local port). Short
    /// timeout — detection must fail fast when Ollama isn't running so the UI
    /// doesn't hang. Never throws; returns an unreachable result on any error.
    public static func detect(baseURL: String? = nil) async -> Detection {
        let base = (baseURL?.isEmpty ?? true) ? AIConfig.defaultOllamaURL : baseURL!
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        let url = "\(trimmed)/api/tags"
        do {
            let response = try await HTTPClient.get(url: url, timeout: 3)
            let models = parseTags(response.json)
            return Detection(baseURL: trimmed, models: models, didRespond: true)
        } catch {
            return Detection(baseURL: trimmed, models: [], didRespond: false)
        }
    }

    /// Parse the `/api/tags` JSON (`{"models": [{"name": "llama3.2:latest", …}, …]}`)
    /// into a model list. Tolerant of missing/odd shapes — returns what it can.
    public static func parseTags(_ json: Any?) -> [Model] {
        guard let object = json as? [String: Any],
              let models = object["models"] as? [Any] else { return [] }
        var out: [Model] = []
        for entry in models {
            if let name = (entry as? [String: Any])?["name"] as? String, !name.isEmpty {
                out.append(Model(name: name))
            }
        }
        return out
    }
}
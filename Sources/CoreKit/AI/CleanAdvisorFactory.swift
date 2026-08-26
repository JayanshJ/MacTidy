import Foundation

/// Builds the concrete `CleanAdvisor` for the configured provider, reading
/// the API key from the Keychain. Returns nil when no provider is configured
/// — callers fall back to the deterministic `Recommendations` ranking so the
/// app works identically without AI.
public enum CleanAdvisorFactory {
    public static func make(config: AIConfig) -> CleanAdvisor? {
        switch config.provider {
        case .none:
            return nil
        case .ollama:
            let base = config.ollamaBaseURL.isEmpty ? AIConfig.defaultOllamaURL : config.ollamaBaseURL
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            let endpoint = "\(trimmed)/v1/chat/completions"
            let model = config.model.isEmpty ? AIProvider.ollama.defaultModel : config.model
            // Ollama's key is optional — only sent if the user stored one
            // (e.g. Ollama behind an auth proxy expecting a Bearer token).
            let key = KeychainHelper.load(for: .ollama)
            return OpenAICompatibleAdvisor(endpoint: endpoint, apiKey: key, model: model)
        case .openai:
            guard let key = KeychainHelper.load(for: .openai) else { return nil }
            let model = config.model.isEmpty ? AIProvider.openai.defaultModel : config.model
            return OpenAICompatibleAdvisor(
                endpoint: "https://api.openai.com/v1/chat/completions",
                apiKey: key,
                model: model
            )
        case .anthropic:
            guard let key = KeychainHelper.load(for: .anthropic) else { return nil }
            return AnthropicAdvisor(apiKey: key)
        }
    }
}
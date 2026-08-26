import Foundation

/// Which cloud/local AI provider a `CleanAdvisor` talks to.
public enum AIProvider: String, CaseIterable, Sendable, Identifiable, Codable {
    case none
    case ollama
    case openai
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .ollama: "Ollama (local)"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    /// Whether this provider needs an API key. Ollama runs locally and needs
    /// none — just a base URL. Cloud providers (OpenAI, Anthropic) require one.
    public var requiresAPIKey: Bool {
        switch self {
        case .none, .ollama: false
        case .openai, .anthropic: true
        }
    }

    /// Whether the user *can* enter a key for this provider. Every provider
    /// except `.none` offers a key field: for OpenAI/Anthropic it's required
    /// (`requiresAPIKey`), for Ollama it's optional — handy when Ollama sits
    /// behind an auth proxy that expects a `Bearer` token.
    public var offersAPIKey: Bool {
        switch self {
        case .none: false
        case .ollama, .openai, .anthropic: true
        }
    }

    public var defaultModel: String {
        switch self {
        case .none: ""
        case .ollama: "llama3.2"
        case .openai: "gpt-4o-mini"
        case .anthropic: "claude-3-5-sonnet-latest"
        }
    }
}

/// Persistent AI configuration: provider, model, base URL (Ollama), and the
/// privacy toggle for sending file paths to the model. The API key itself is
/// stored separately in the Keychain (see `KeychainHelper`) — never here, so
/// it never lands in UserDefaults or a plist on disk.
public struct AIConfig: Sendable, Codable, Equatable {
    public var provider: AIProvider
    public var model: String
    /// Base URL for Ollama (default http://localhost:11434). Ignored by cloud
    /// providers, which have fixed endpoints.
    public var ollamaBaseURL: String
    /// When true, file paths/names may be sent to the model for richer
    /// per-file reasoning. Default false — only labels+counts+sizes leave the
    /// machine. Ollama is local, so this is only a privacy concern for cloud
    /// providers.
    public var sendFilePaths: Bool

    public init(
        provider: AIProvider = .none,
        model: String = "",
        ollamaBaseURL: String = "http://localhost:11434",
        sendFilePaths: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.ollamaBaseURL = ollamaBaseURL
        self.sendFilePaths = sendFilePaths
    }

    public static let defaultOllamaURL = "http://localhost:11434"
}
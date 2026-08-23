import Foundation

/// The advice an AI provider returns: a one-line reasoning + a set of
/// `ScanItem`s it proposes for deletion. This is *always* a suggestion — it
/// becomes a `DeletionPlan` that flows through the existing `SafePathPolicy`
/// + confirmation sheet, so the model never executes and a hallucinated path
/// is denied per-item like any scanner bug.
public struct AdvicePlan: Sendable {
    public let reasoning: String
    public let items: [ScanItem]

    public init(reasoning: String, items: [ScanItem]) {
        self.reasoning = reasoning
        self.items = items
    }
}

/// A per-item explanation (Feature 3) or big-file classification (Feature 2).
public struct ItemExplanation: Sendable {
    public enum Verdict: String, Sendable {
        case safe = "Safe to delete"
        case review = "Review carefully"
        case keep = "Don't delete"

        public var icon: String {
            switch self {
            case .safe: "checkmark.circle.fill"
            case .review: "exclamationmark.triangle.fill"
            case .keep: "xmark.octagon.fill"
            }
        }
    }

    public let summary: String
    public let verdict: Verdict?

    public init(summary: String, verdict: Verdict? = nil) {
        self.summary = summary
        self.verdict = verdict
    }
}

/// The abstraction every AI provider implements. Pure CoreKit, no UI, so it's
/// unit-testable with a mock client. All methods are `async throws` — callers
/// (the UI) wrap failures and fall back to the deterministic `Recommendations`
/// ranking so the app works identically without AI.
public protocol CleanAdvisor: Sendable {
    /// Propose a cleanup plan for a natural-language intent ("free up 15 GB",
    /// "clean Xcode stuff"), given the current scan results. The advisor
    /// sanitizes what it sends per `AIConfig.sendFilePaths`.
    func plan(
        for intent: String,
        categories: [CategoryResult],
        config: AIConfig
    ) async throws -> AdvicePlan

    /// Explain a single scanned item: a one-line consequence of deleting it,
    /// optionally with a safe/review/keep verdict.
    func explain(
        _ item: ScanItem,
        config: AIConfig
    ) async throws -> ItemExplanation

    /// Generate proactive insights over the full system snapshot (disk +
    /// memory + processes). Returns narrative reasoning + proposed actions,
    /// sorted by priority. The model never executes — each action routes
    /// through the existing confirmation flow.
    func insights(
        for snapshot: SystemSnapshot,
        config: AIConfig
    ) async throws -> [Insight]

    /// Light-weight connectivity check used by the Settings "Test connection"
    /// button. Returns a short human-readable status string.
    func testConnection(config: AIConfig) async -> String
}
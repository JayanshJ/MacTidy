import Testing
import Foundation
@testable import CoreKit

@Suite("CleanAdvisor batch verdicts")
struct BatchVerdictTests {
    /// A minimal advisor that returns canned verdicts, to exercise the
    /// protocol's default loop and the BatchVerdict shape end-to-end.
    private struct MockAdvisor: CleanAdvisor {
        func plan(for intent: String, categories: [CategoryResult], config: AIConfig) async throws -> AdvicePlan {
            AdvicePlan(reasoning: "mock", items: [])
        }
        func explain(_ item: ScanItem, config: AIConfig) async throws -> ItemExplanation {
            ItemExplanation(summary: "mock note", verdict: .safe)
        }
        func insights(for snapshot: SystemSnapshot, config: AIConfig) async throws -> [Insight] { [] }
        func testConnection(config: AIConfig) async -> String { "Connected" }
    }

    @Test("default explainBatch loops explain and keys verdicts by id")
    func defaultLoopKeysById() async throws {
        let advisor = MockAdvisor()
        let items = [
            ScanItem(url: URL(fileURLWithPath: "/tmp/a"), sizeBytes: 10, isDirectory: false),
            ScanItem(url: URL(fileURLWithPath: "/tmp/b"), sizeBytes: 20, isDirectory: false),
        ]
        let verdicts = try await advisor.explainBatch(items, config: AIConfig())
        #expect(verdicts.count == 2)
        #expect(verdicts[0].id == items[0].id)
        #expect(verdicts[1].id == items[1].id)
        #expect(verdicts.allSatisfy { $0.verdict == .safe })
        #expect(verdicts.allSatisfy { $0.summary == "mock note" })
    }

    @Test("explainBatch on empty input returns empty")
    func emptyBatch() async throws {
        let advisor = MockAdvisor()
        let verdicts = try await advisor.explainBatch([], config: AIConfig())
        #expect(verdicts.isEmpty)
    }

    @Test("BatchVerdict carries verdict + summary")
    func verdictShape() {
        let v = BatchVerdict(id: UUID(), verdict: .review, summary: "check before deleting")
        #expect(v.verdict == .review)
        #expect(v.summary == "check before deleting")
    }

    @Test("AdvisorPrompts.explainBatchUser includes indices and sizes")
    func batchPromptShape() {
        let items = [
            ScanItem(url: URL(fileURLWithPath: "/tmp/a"), sizeBytes: 1024, isDirectory: false),
        ]
        let prompt = AdvisorPrompts.explainBatchUser(items: items, sendFilePaths: false)
        #expect(prompt.contains("\"index\""))
        #expect(prompt.contains("verdict_items"))
    }
}
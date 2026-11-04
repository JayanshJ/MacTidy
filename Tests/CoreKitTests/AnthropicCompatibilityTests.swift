import Testing
@testable import CoreKit

@Suite("Anthropic compatibility")
struct AnthropicCompatibilityTests {
    @Test func sonnet55RemovesSamplingAndDisablesUpfrontThinking() {
        let body = AnthropicAdvisor.compatibleBody(["model": "claude-sonnet-5-5", "temperature": 0.2])
        #expect(body["temperature"] == nil)
        #expect((body["thinking"] as? [String: String])?["type"] == "between_tools")
        #expect(body["model"] as? String == "claude-sonnet-5-5")
    }
    @Test func existingModelsKeepTheirOwnThinkingDefaults() {
        let body = AnthropicAdvisor.compatibleBody(["model": "claude-haiku-4-5-20251001"])
        #expect(body["thinking"] == nil)
    }
    @Test func onlyRetiredBuiltInDefaultMigrates() {
        let old = AIConfig(provider: .anthropic, model: "claude-3-5-sonnet-latest")
        #expect(old.replacingRetiredDefault.model == "claude-sonnet-5-5")
        let custom = AIConfig(provider: .anthropic, model: "my-custom-model")
        #expect(custom.replacingRetiredDefault == custom)
    }
}

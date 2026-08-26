import Testing
import Foundation
@testable import CoreKit

@Suite("OllamaDetector")
struct OllamaDetectorTests {
    @Test("parseTags extracts model names from /api/tags JSON")
    func parseTagsExtractsNames() throws {
        let json: [String: Any] = [
            "models": [
                ["name": "llama3.2:latest", "size": 2_000_000_000],
                ["name": "mistral:7b", "size": 4_000_000_000]
            ]
        ]
        let models = OllamaDetector.parseTags(json)
        #expect(models.map(\.name) == ["llama3.2:latest", "mistral:7b"])
    }

    @Test("parseTags handles empty model list")
    func parseTagsEmpty() {
        let json: [String: Any] = ["models": []]
        #expect(OllamaDetector.parseTags(json).isEmpty)
    }

    @Test("parseTags handles missing models key")
    func parseTagsMissingKey() {
        let json: [String: Any] = ["foo": "bar"]
        #expect(OllamaDetector.parseTags(json).isEmpty)
    }

    @Test("parseTags skips entries without a name")
    func parseTagsSkipsNameless() {
        let json: [String: Any] = [
            "models": [
                ["name": "phi3:mini"],
                ["size": 1234],
                ["name": "", "size": 5]
            ]
        ]
        let models = OllamaDetector.parseTags(json)
        #expect(models.map(\.name) == ["phi3:mini"])
    }

    @Test("parseTags tolerates nil input")
    func parseTagsNil() {
        #expect(OllamaDetector.parseTags(nil).isEmpty)
    }

    @Test("Detection.isReachable reflects models + response")
    func detectionReachability() {
        #expect(OllamaDetector.Detection(baseURL: "x", models: [.init(name: "a")], didRespond: true).isReachable)
        // Responded at all (even with zero models) counts as reachable — the
        // UI distinguishes "running but no models" from "not running".
        #expect(OllamaDetector.Detection(baseURL: "x", models: [], didRespond: true).isReachable)
        #expect(!OllamaDetector.Detection(baseURL: "x", models: [], didRespond: false).isReachable)
    }
}
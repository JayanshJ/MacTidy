import Foundation
import Testing
@testable import CoreKit

@Suite("CleanSource registry, risk tiers, credential denylist")
struct CleanSourceTests {
    func makeFakeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func seed(_ home: URL, _ relative: String, bytes: Int = 4096) throws {
        let file = home.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(count: bytes).write(to: file)
    }

    // MARK: Registry invariants

    @Test func everySourceIsTrashableUnderPolicy() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let policy = SafePathPolicy(home: home)
        for source in CleanSource.all {
            let result = policy.classify(home.appending(path: source.path).appending(path: "item"))
            if case .failure(let v) = result { Issue.record("\(source.path): \(v)") }
        }
    }

    @Test func sourcePathsAreUnique() {
        let paths = CleanSource.all.map(\.path)
        #expect(Set(paths).count == paths.count)
    }

    /// A source nested inside another is only allowed when the outer one is
    /// split per child (children skip other sources), else bytes double-count.
    @Test func nestedSourcesOnlyUnderChildrenSources() {
        for outer in CleanSource.all {
            for inner in CleanSource.all where inner.path.hasPrefix(outer.path + "/") {
                #expect(outer.locate == .children, "\(inner.path) nested in whole \(outer.path)")
            }
        }
    }

    // MARK: Scanning

    @Test func aiAgentsScanTiersAndNoDoubleCount() async throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, ".claude/debug/session.txt")
        try seed(home, ".claude/projects/-Users-me-app/abc.jsonl")
        try seed(home, ".claude/settings.json")
        try seed(home, ".codex/worktrees/fix-bug/file.swift")
        try seed(home, ".codex/auth.json")
        try seed(home, ".cache/codex-runtimes/primary/bin")
        try seed(home, ".cache/huggingface/hub/models--org--m/blob")
        try seed(home, ".cache/huggingface/token", bytes: 64)
        try seed(home, ".cache/pip/wheel.whl")

        let scanner = CategoryScanner(home: home)
        let ai = await scanner.scan(.aiAgents).items
        let names = Set(ai.map(\.url.lastPathComponent))
        #expect(names == ["debug", "-Users-me-app", "fix-bug", "codex-runtimes", "models--org--m"])

        let debug = try #require(ai.first { $0.url.lastPathComponent == "debug" })
        #expect(debug.risk == .safe && debug.isPreselectable)
        let transcript = try #require(ai.first { $0.url.lastPathComponent == "-Users-me-app" })
        #expect(transcript.risk == .caution && !transcript.isPreselectable)
        let worktree = try #require(ai.first { $0.url.lastPathComponent == "fix-bug" })
        #expect(worktree.risk == .caution)

        // ~/.cache is listed per child; children owned by AI sources are skipped.
        let dev = await scanner.scan(.devCaches).items.map(\.url.lastPathComponent)
        #expect(dev == ["pip"])
    }

    // MARK: Recommendations and scheduling respect item risk

    @Test func cautionItemsAreSuggestOnlyNeverAutoSelected() {
        let base = URL(fileURLWithPath: "/tmp/h")
        let safe = ScanItem(url: base.appending(path: ".claude/debug"), sizeBytes: 1_000_000,
                            isDirectory: true, category: .aiAgents)
        let model = ScanItem(url: base.appending(path: ".ollama/models"), sizeBytes: 9_000_000_000,
                             isDirectory: true, category: .aiAgents)
        let results = [CategoryResult(category: .aiAgents, items: [safe, model])]

        let ranked = Recommendations.ranked(from: results)
        #expect(ranked.map(\.item.id) == [safe.id])
        #expect(Recommendations.autoSelectableIDs(from: ranked) == [safe.id])
        #expect(Recommendations.suggestOnly(from: results).map(\.item.id) == [model.id])
    }

    /// Saved scans from before the registry list Ollama under devCaches; the
    /// restored item must still be Caution, not silently preselected.
    @Test func restoredOldScanItemGetsCurrentRisk() {
        let old = ScanItem(url: URL(fileURLWithPath: "/tmp/h/.ollama/models"), sizeBytes: 1,
                           isDirectory: true, category: .devCaches)
        #expect(old.risk == .caution)
        #expect(!old.isPreselectable)
    }

    @Test func scheduledRunSkipsDangerItemsInSafeCategory() async throws {
        let sandbox = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let vm = ScanItem(url: sandbox.appending(path: ".colima"), sizeBytes: 1,
                          isDirectory: true, category: .devCaches)
        let job = ScheduledJob(cadence: .daily, hour: 0, categories: [.devCaches],
                               nextRun: Date().addingTimeInterval(-60))
        let result = await ScheduledRunner.run(
            jobs: [job], now: Date(),
            scan: { _ in [CategoryResult(category: .devCaches, items: [vm])] },
            executor: DeletionExecutor(policy: SafePathPolicy(extraAllowedRoots: [sandbox])))
        #expect(result?.plan.isEmpty == true)
    }

    // MARK: Credential denylist

    @Test(arguments: [
        ".claude.json", ".claude/.credentials.json", ".claude/settings.json",
        ".codex/auth.json", ".codex/config.toml", ".gemini/oauth_creds.json",
        ".ssh/id_ed25519", ".aws/credentials", ".config/gh/hosts.yml",
        ".cache/huggingface/token", ".docker/config.json", ".netrc",
        // Ancestors: trashing the folder would trash the secret inside.
        ".claude", ".codex", ".ssh", ".config", ".docker",
    ])
    func credentialPathsAndAncestorsAreDenied(_ relative: String) throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: relative)
        // Even a user-picked root covering the secret cannot unlock it.
        let policy = SafePathPolicy(home: home, extraAllowedRoots: [home.appending(path: ".config"), url])
        guard case .failure(.credentialPath) = policy.classify(url) else {
            Issue.record("\(relative) was not denied as a credential path"); return
        }
    }

    @Test func agentSubfoldersBesideSecretsStayTrashable() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let policy = SafePathPolicy(home: home)
        for relative in [".claude/debug/log.txt", ".claude/projects/p", ".codex/sessions/2026",
                         ".cache/huggingface/hub/models--a--b"] {
            if case .failure(let v) = policy.classify(home.appending(path: relative)) {
                Issue.record("\(relative): \(v)")
            }
        }
    }

    /// Dotfile managers symlink secrets into a repo; the real file and the
    /// folder holding it are protected wherever they live.
    @Test func symlinkedSecretIsDeniedAtItsTarget() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "dotfiles/npmrc", bytes: 16)
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".npmrc"), withDestinationURL: home.appending(path: "dotfiles/npmrc"))

        let policy = SafePathPolicy(home: home)
        guard case .failure(.credentialPath) = policy.classify(home.appending(path: "dotfiles/npmrc")),
              case .failure(.credentialPath) = policy.classify(home.appending(path: "dotfiles")) else {
            Issue.record("symlinked secret target not denied"); return
        }
        if case .failure(let v) = policy.classify(home.appending(path: "dotfiles/other")) {
            Issue.record("unrelated sibling denied: \(v)")
        }
    }
}

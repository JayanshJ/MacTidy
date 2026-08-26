import Foundation
import Testing
@testable import CoreKit

@Suite("ShellActionExecutor")
struct ShellActionExecutorTests {
    /// A test action wrapping an arbitrary command. `shouldFail` makes it run
    /// `/bin/false` so exitCode != 0.
    struct TestAction: ShellAction {
        let id = UUID()
        let displayName: String
        let commandSummary: String
        let reversible = false
        let estimatedBytes: Int64
        let shouldFail: Bool
        var commandPath: String { shouldFail ? "/usr/bin/false" : "/usr/bin/true" }
        func run() -> Shell.Output? { Shell.run(commandPath, []) }
    }

    @Test func successfulActionSucceedsAndCountsBytes() {
        let action = TestAction(displayName: "t", commandSummary: "docker rmi abc",
                                estimatedBytes: 500, shouldFail: false)
        let outcome = ShellActionExecutor.execute([action])
        #expect(outcome.succeeded.count == 1)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.reclaimedBytes == 500)
    }

    @Test func failingActionDoesNotAbortTheRest() {
        let good = TestAction(displayName: "good", commandSummary: "docker rmi good",
                              estimatedBytes: 300, shouldFail: false)
        let bad = TestAction(displayName: "bad", commandSummary: "docker rmi bad",
                             estimatedBytes: 700, shouldFail: true)
        let outcome = ShellActionExecutor.execute([bad, good])
        #expect(outcome.succeeded.count == 1)
        #expect(outcome.succeeded.first?.displayName == "good")
        #expect(outcome.failed.count == 1)
        #expect(outcome.failed.first?.action.displayName == "bad")
        // Reclaimed bytes only counts succeeded actions.
        #expect(outcome.reclaimedBytes == 300)
        // Failure carries a non-empty message (stderr or fallback).
        #expect((outcome.failed.first?.message.isEmpty ?? true) == false)
    }

    @Test func emptyBatchIsHarmless() {
        let outcome = ShellActionExecutor.execute([])
        #expect(outcome.succeeded.isEmpty)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.reclaimedBytes == 0)
    }
}
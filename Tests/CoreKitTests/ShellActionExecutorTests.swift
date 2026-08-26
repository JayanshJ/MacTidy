import Foundation
import Testing
@testable import CoreKit

/// `ShellActionExecutor` is pure logic over the `ShellAction` protocol — per-item
/// fail-closed execution, where a failure is reported and never aborts the batch.
/// These tests pin that contract with a stub action that succeeds/fails on
/// command, without shelling out to anything.
@Suite("ShellActionExecutor")
struct ShellActionExecutorTests {
    /// A deterministic `ShellAction` whose `run()` returns a configured result,
    /// so we can exercise success, non-zero exit, and launch-failure paths.
    private struct StubAction: ShellAction {
        let id = UUID()
        let displayName: String
        let commandSummary: String
        let reversible: Bool = false
        let estimatedBytes: Int64
        let result: Shell.Output?

        func run() -> Shell.Output? { result }
    }

    @Test func emptyBatchReturnsEmptyOutcome() {
        let outcome = ShellActionExecutor.execute([])
        #expect(outcome.succeeded.isEmpty)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.reclaimedBytes == 0)
    }

    @Test func allSucceedAreRecordedWithReclaimedBytes() {
        let a = StubAction(displayName: "A", commandSummary: "rm a", estimatedBytes: 100,
                           result: Shell.Output(stdout: "", stderr: "", exitCode: 0))
        let b = StubAction(displayName: "B", commandSummary: "rm b", estimatedBytes: 250,
                           result: Shell.Output(stdout: "", stderr: "", exitCode: 0))
        let outcome = ShellActionExecutor.execute([a, b])
        #expect(outcome.succeeded.count == 2)
        #expect(outcome.failed.isEmpty)
        // reclaimedBytes sums the *succeeded* actions' estimates.
        #expect(outcome.reclaimedBytes == 350)
    }

    @Test func nonZeroExitIsFailureButDoesNotAbortBatch() {
        // The middle action fails (exit 1); the ones before and after still run.
        let a = StubAction(displayName: "A", commandSummary: "rm a", estimatedBytes: 100,
                           result: Shell.Output(stdout: "", stderr: "", exitCode: 0))
        let bad = StubAction(displayName: "bad", commandSummary: "rm bad", estimatedBytes: 999,
                             result: Shell.Output(stdout: "", stderr: "no such container", exitCode: 1))
        let c = StubAction(displayName: "C", commandSummary: "rm c", estimatedBytes: 50,
                           result: Shell.Output(stdout: "", stderr: "", exitCode: 0))
        let outcome = ShellActionExecutor.execute([a, bad, c])
        #expect(outcome.succeeded.count == 2)          // a and c
        #expect(outcome.failed.count == 1)            // bad
        // Failed action's bytes are NOT counted toward reclaim.
        #expect(outcome.reclaimedBytes == 150)
        let failure = outcome.failed.first
        #expect(failure?.action.displayName == "bad")
        #expect(failure?.message == "no such container")
    }

    @Test func nilOutputIsLaunchFailureWithHelpfulMessage() {
        // `run()` returning nil means the process couldn't be launched at all.
        let dead = StubAction(displayName: "dead", commandSummary: "docker rm x",
                              estimatedBytes: 10, result: nil)
        let outcome = ShellActionExecutor.execute([dead])
        #expect(outcome.succeeded.isEmpty)
        #expect(outcome.failed.count == 1)
        #expect(outcome.failed.first?.message == "Failed to launch command.")
    }

    @Test func emptyStderrFallsBackToExitCodeMessage() {
        let silent = StubAction(displayName: "silent", commandSummary: "rm x",
                                estimatedBytes: 5,
                                result: Shell.Output(stdout: "", stderr: "   ", exitCode: 2))
        let outcome = ShellActionExecutor.execute([silent])
        #expect(outcome.failed.count == 1)
        // Whitespace-only stderr → a synthesized "exited with code N" message
        // rather than an empty, unhelpful one.
        #expect(outcome.failed.first?.message == "Command exited with code 2.")
    }
}
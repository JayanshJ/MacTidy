import Foundation
import Testing
@testable import CoreKit

/// `ShellAction` conformances for the Developer Terminal module. Tests pin
/// the command strings, reversibility, and the PID/denylist guards on
/// `KillProcessAction` — the safety-critical one. No real shelling out:
/// `run()` is only called for the guard-rejection tests (which return nil
/// before reaching `Shell.run`), and the command-string tests are pure.
@Suite("DevTerminalActions")
struct DevTerminalActionsTests {
    // MARK: - KillProcessAction guards

    @Test func killActionRefusesPID1() {
        let action = KillProcessAction(pid: 1, name: "launchd")
        #expect(action.run() == nil)
    }

    @Test func killActionRefusesPID0() {
        let action = KillProcessAction(pid: 0, name: "kernel_task")
        #expect(action.run() == nil)
    }

    @Test func killActionRefusesNegativePID() {
        let action = KillProcessAction(pid: -1, name: "unknown")
        #expect(action.run() == nil)
    }

    @Test func killActionRefusesDenylistedName() {
        let action = KillProcessAction(pid: 42, name: "Finder")
        #expect(action.run() == nil)
    }

    @Test func killActionRefusesWindowServer() {
        let action = KillProcessAction(pid: 99, name: "WindowServer")
        #expect(action.run() == nil)
    }

    // MARK: - Command strings (pure — no execution)

    @Test func killCommandSummaryIsSIGTERM() {
        let action = KillProcessAction(pid: 4521, name: "node", port: 3000)
        #expect(action.commandSummary == "kill -TERM 4521")
    }

    @Test func killDisplayNameIncludesPort() {
        let action = KillProcessAction(pid: 4521, name: "node", port: 3000)
        #expect(action.displayName == "Kill node (PID 4521, port 3000)")
    }

    @Test func killDisplayNameOmitsPortWhenNil() {
        let action = KillProcessAction(pid: 4521, name: "node")
        #expect(action.displayName == "Kill node (PID 4521)")
    }

    @Test func npmCacheCleanCommandSummary() {
        let action = NpmCacheCleanAction(estimatedBytes: 100)
        #expect(action.commandSummary == "npm cache clean --force")
    }

    @Test func yarnCacheCleanCommandSummary() {
        let action = YarnCacheCleanAction()
        #expect(action.commandSummary == "yarn cache clean")
    }

    @Test func pnpmStorePruneCommandSummary() {
        let action = PnpmStorePruneAction()
        #expect(action.commandSummary == "pnpm store prune")
    }

    @Test func brewCleanupCommandSummary() {
        let action = BrewCleanupAction()
        #expect(action.commandSummary == "brew cleanup --prune=0")
    }

    @Test func cargoCacheCleanCommandSummary() {
        let action = CargoCacheCleanAction()
        #expect(action.commandSummary == "trash ~/.cargo/registry/cache + ~/.cargo/registry/src")
    }

    @Test func dockerVolumePruneCommandSummary() {
        let action = DockerVolumePruneAction()
        #expect(action.commandSummary == "docker volume prune -f")
    }

    @Test func simctlDeleteUnavailableCommandSummary() {
        let action = SimctlDeleteUnavailableAction(unavailableCount: 3)
        #expect(action.commandSummary == "xcrun simctl delete unavailable")
    }

    @Test func simctlDisplayNameIncludesCount() {
        let action = SimctlDeleteUnavailableAction(unavailableCount: 5)
        #expect(action.displayName == "unavailable iOS Simulators (5)")
    }

    // MARK: - Reversibility (all must be false)

    @Test func allActionsAreNonReversible() {
        let actions: [any ShellAction] = [
            KillProcessAction(pid: 100, name: "node"),
            NpmCacheCleanAction(),
            YarnCacheCleanAction(),
            PnpmStorePruneAction(),
            BrewCleanupAction(),
            CargoCacheCleanAction(),
            DockerVolumePruneAction(),
            SimctlDeleteUnavailableAction(),
        ]
        for action in actions {
            #expect(action.reversible == false, "\(action.displayName) should be non-reversible")
        }
    }

    // MARK: - DevToolScanner parsers (pure)

    @Test func parseDuBytesExtractsKilobytes() {
        let stdout = "482304\t/Users/jayansh/.npm\n"
        #expect(DevToolScanner.parseDuBytes(stdout) == Int64(482304 * 1024))
    }

    @Test func parseDuBytesHandlesNoTrailingNewline() {
        #expect(DevToolScanner.parseDuBytes("0\t/empty") == 0)
    }

    @Test func parseDuBytesReturnsNilForGarbage() {
        #expect(DevToolScanner.parseDuBytes("not a number\t/path") == nil)
        #expect(DevToolScanner.parseDuBytes("") == nil)
        #expect(DevToolScanner.parseDuBytes("no tab here") == nil)
    }

    @Test func parseSimctlUnavailableCountsDeviceLines() {
        let fixture = """
        == Unavailable ==
        iPhone 15 (xxx-yyy-zzz) (shutdown)
        iPad Pro (aaa-bbb-ccc) (shutdown)
        iPhone 14 (ddd-eee-fff) (shutdown)
        """
        #expect(DevToolScanner.parseSimctlUnavailable(fixture) == 3)
    }

    @Test func parseSimctlUnavailableIgnoresSectionHeaders() {
        let fixture = """
        == Unavailable ==
        iPhone 15 (xxx) (shutdown)
        iOS 17.0:
        iPad Pro (aaa) (shutdown)
        """
        // "iOS 17.0:" ends with ":" so it's excluded; 2 device lines counted.
        #expect(DevToolScanner.parseSimctlUnavailable(fixture) == 2)
    }

    @Test func parseSimctlUnavailableEmptyReturnsZero() {
        #expect(DevToolScanner.parseSimctlUnavailable("") == 0)
        #expect(DevToolScanner.parseSimctlUnavailable("== Unavailable ==\n") == 0)
    }

    // MARK: - DevTool metadata

    @Test func devToolAllCasesCoverExpectedTools() {
        let tools = DevTool.allCases.map(\.rawValue)
        #expect(tools.contains("npm"))
        #expect(tools.contains("yarn"))
        #expect(tools.contains("pnpm"))
        #expect(tools.contains("brew"))
        #expect(tools.contains("cargo"))
        #expect(tools.contains("simctl"))
    }

    @Test func devToolCleanDescriptionsAreNonEmpty() {
        for tool in DevTool.allCases {
            #expect(!tool.cleanDescription.isEmpty, "\(tool) has no clean description")
        }
    }
}
import Foundation
import Testing
@testable import CoreKit

@Suite("SystemMaintenance and SystemTweaks")
struct SystemMaintenanceTests {
    @Test func maintenanceActionsExposeTransparentCommands() {
        let actions: [any ShellAction] = [
            ResetQuickLookCacheAction(),
            ClearFontCacheAction(),
            RestartFinderAction(),
            RestartDockAction(),
            RebuildSpotlightIndexAction(),
            ThinTimeMachineSnapshotsAction(targetBytes: 5_000_000_000),
        ]
        for action in actions {
            #expect(action.reversible == false)
            #expect(!action.commandSummary.isEmpty)
        }
        #expect(ResetQuickLookCacheAction().commandSummary == "qlmanage -r && qlmanage -r cache")
        #expect(ThinTimeMachineSnapshotsAction(targetBytes: 5_000_000_000).commandSummary == "tmutil thinlocalsnapshots / 5000000000 4")
    }

    @Test func tweakCommandPreviewsIncludeDefaultsAndKillallWhenNeeded() {
        let finderTweak = SystemTweaks.catalog.first { $0.id == "finder-path-bar" }!
        #expect(finderTweak.writeCommandPreview(boolValue: true) == "defaults write com.apple.finder ShowPathbar -bool true && killall Finder")
        #expect(finderTweak.resetCommandPreview == "defaults delete com.apple.finder ShowPathbar && killall Finder")

        let kbTweak = SystemTweaks.catalog.first { $0.id == "keyboard-press-and-hold" }!
        #expect(kbTweak.writeCommandPreview(boolValue: false) == "defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false")
    }

    @Test func parsesDefaultsBoolVariants() {
        #expect(SystemTweaks.parseBool("1") == true)
        #expect(SystemTweaks.parseBool("true\n") == true)
        #expect(SystemTweaks.parseBool("YES") == true)
        #expect(SystemTweaks.parseBool("0") == false)
        #expect(SystemTweaks.parseBool("false") == false)
        #expect(SystemTweaks.parseBool("invalid") == nil)
        #expect(SystemTweaks.parseBool(nil) == nil)
    }

    @Test func readAllReadsValuesAndMarksDefaultsUncustomized() {
        let states = SystemTweaks.readAll { _, args in
            if args == ["read", "com.apple.finder", "ShowPathbar"] {
                return Shell.Output(stdout: "1\n", stderr: "", exitCode: 0)
            }
            if args == ["read", "com.apple.dock", "autohide-delay"] {
                return Shell.Output(stdout: "0\n", stderr: "", exitCode: 0)
            }
            return Shell.Output(stdout: "", stderr: "does not exist", exitCode: 1)
        }
        let pathBar = states.first { $0.id == "finder-path-bar" }!
        #expect(pathBar.isCustomized == true)
        #expect(pathBar.boolValue == true)

        let dockDelay = states.first { $0.id == "dock-autohide-delay" }!
        #expect(dockDelay.isCustomized == true)
        #expect(dockDelay.selectedChoiceValue == "0")

        let hidden = states.first { $0.id == "finder-hidden-files" }!
        #expect(hidden.isCustomized == false)
        #expect(hidden.boolValue == false)
    }

    @Test func setBoolSetChoiceAndResetInvokeDefaultsAndRestartTarget() {
        var calls: [[String]] = []
        let finderTweak = SystemTweaks.catalog.first { $0.id == "finder-path-bar" }!
        let okSet = SystemTweaks.setBool(true, for: finderTweak) { exe, args in
            calls.append([exe] + args)
            return Shell.Output(stdout: "", stderr: "", exitCode: 0)
        }
        #expect(okSet == true)
        #expect(calls == [
            ["/usr/bin/defaults", "write", "com.apple.finder", "ShowPathbar", "-bool", "true"],
            ["/usr/bin/killall", "Finder"],
        ])

        calls.removeAll()
        let okReset = SystemTweaks.reset(finderTweak) { exe, args in
            calls.append([exe] + args)
            if args.first == "delete" {
                return Shell.Output(stdout: "", stderr: "Domain (com.apple.finder) not found.", exitCode: 1)
            }
            return Shell.Output(stdout: "", stderr: "", exitCode: 0)
        }
        #expect(okReset == true)
        #expect(calls == [
            ["/usr/bin/defaults", "delete", "com.apple.finder", "ShowPathbar"],
            ["/usr/bin/killall", "Finder"],
        ])
    }

    @Test func catalogHasUniqueIDs() {
        let ids = SystemTweaks.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

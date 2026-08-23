import Foundation
import Testing
@testable import CoreKit

/// The process denylist is the safety boundary for the memory/quit feature —
/// a regression here could suggest quitting a system process and destabilize
/// the OS. Lock it in.
@Suite("Process denylist")
struct ProcessDenylistTests {
    @Test func systemEssentialsAreDenied() {
        #expect(ProcessDenylist.isDenied("kernel_task"))
        #expect(ProcessDenylist.isDenied("WindowServer"))
        #expect(ProcessDenylist.isDenied("loginwindow"))
        #expect(ProcessDenylist.isDenied("Dock"))
        #expect(ProcessDenylist.isDenied("Finder"))
        #expect(ProcessDenylist.isDenied("launchd"))
    }

    @Test func macTidyItselfIsDenied() {
        // Never suggest quitting the app you're using to do the cleanup.
        #expect(ProcessDenylist.isDenied("MacTidy"))
    }

    @Test func userAppsAreNotDenied() {
        #expect(!ProcessDenylist.isDenied("Slack"))
        #expect(!ProcessDenylist.isDenied("Google Chrome"))
        #expect(!ProcessDenylist.isDenied("Xcode"))
    }
}

/// Insight resolution: the resolver must enforce the denylist and only
/// propose quitting real running user apps, and only trash items that
/// actually exist in the scan.
@Suite("Insight resolver")
struct InsightResolverTests {
    private func snapshot() -> SystemSnapshot {
        let cat = CategoryResult(category: .userCaches, items: [
            ScanItem(url: URL(fileURLWithPath: "/tmp/fake-cache"), sizeBytes: 1_000_000, isDirectory: true)
        ])
        let procs: [RunningProcess] = [
            RunningProcess(pid: 100, name: "Slack", appBundlePath: "/Applications/Slack.app",
                           residentBytes: 800_000_000, cpuPercent: 0.1, idleSeconds: 3600),
            RunningProcess(pid: 1, name: "kernel_task", appBundlePath: nil,
                           residentBytes: 2_000_000_000, cpuPercent: 5, idleSeconds: 0),
        ]
        return SystemSnapshot(categories: [cat], memory: nil, processes: procs)
    }

    @Test func quitInsightFiltersDeniedAndSystemProcesses() {
        let raw: [String: Any] = [
            "insights": [
                [
                    "kind": "processes",
                    "reasoning": "Quit Slack",
                    "action": "quit",
                    "quitApps": ["Slack", "kernel_task", "Nonexistent"],
                    "priority": 10,
                ]
            ]
        ]
        let insights = InsightResolver.resolve(raw, snapshot: snapshot())
        #expect(insights.count == 1)
        if case .quitApps(let names) = insights.first?.action {
            // kernel_task is denied/has no bundle; Nonexistent isn't running.
            #expect(names == ["Slack"])
        } else {
            #expect(Bool(false), "expected a quitApps action")
        }
    }

    @Test func trashInsightOnlyReturnsRealItems() {
        let raw: [String: Any] = [
            "insights": [
                [
                    "kind": "disk",
                    "reasoning": "Clear caches",
                    "action": "trash",
                    "trashSelection": [
                        ["category": "User caches", "indices": [0, 99]],  // 99 is out of range
                        ["category": "Nonexistent", "indices": [0]],      // bogus category
                    ],
                    "priority": 20,
                ]
            ]
        ]
        let insights = InsightResolver.resolve(raw, snapshot: snapshot())
        #expect(insights.count == 1)
        if case .trash(let items) = insights.first?.action {
            #expect(items.count == 1)  // only the valid index 0 in User caches
        } else {
            #expect(Bool(false))
        }
    }

    @Test func observeInsightPassesThrough() {
        let raw: [String: Any] = [
            "insights": [
                ["kind": "memory", "reasoning": "All fine", "action": "observe", "priority": 1]
            ]
        ]
        let insights = InsightResolver.resolve(raw, snapshot: snapshot())
        #expect(insights.count == 1)
        #expect(insights.first?.action == .observe)
    }
}
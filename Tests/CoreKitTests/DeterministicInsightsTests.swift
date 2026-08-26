import Foundation
import Testing
@testable import CoreKit

/// The new disk-pressure and heavy-startup signals added in the broader
/// health-insights work. Both must stay honest: the disk-almost-full insight
/// only fires when free space is genuinely low AND there's a safe category to
/// clear; the startup insight is observe-only (never a destructive action).
@Suite("Deterministic insights — disk pressure & startup")
struct DeterministicInsightsPressureTests {
    private func safeCategory(bytes: Int64) -> CategoryResult {
        CategoryResult(category: .userCaches, items: [
            ScanItem(url: URL(fileURLWithPath: "/tmp/fake-cache"),
                     sizeBytes: bytes, isDirectory: true)
        ])
    }

    private func makeLaunchItem(_ i: Int) -> LaunchItem {
        LaunchItem(url: URL(fileURLWithPath: "/tmp/agent-\(i).plist"),
                   label: "com.test.agent\(i)",
                   program: "/tmp/agent-\(i)",
                   runAtLoad: true,
                   isLoaded: true,
                   domain: .userAgent)
    }

    @Test func diskAlmostFullUrgentTrashInsight() {
        // 900GB total, 50GB free → ~94% used, well under the 10% threshold.
        let pressure = DiskPressure(totalBytes: 900_000_000_000, freeBytes: 50_000_000_000)
        let snapshot = SystemSnapshot(
            categories: [safeCategory(bytes: 5_000_000_000)],
            memory: nil,
            processes: [],
            diskPressure: pressure,
            launchItems: nil
        )
        let insights = DeterministicInsights.from(snapshot)
        // Expect a disk insight that proposes trashing the safe category,
        // leading with the "Your disk is … full" urgent framing. The plain
        // biggest-category signal also appears, but its reasoning leads with
        // the category name — so we distinguish on the urgent phrasing.
        let urgent = insights.first { $0.reasoning.contains("disk is") && $0.reasoning.contains("full") }
        #expect(urgent != nil)
        #expect((urgent?.priority ?? 0) >= 50)
        if case .trash(let items) = urgent?.action {
            #expect(items.count == 1)
        } else {
            #expect(Bool(false), "expected a trash action on the urgent insight")
        }
    }

    @Test func plentyOfFreeSpaceNoUrgentInsight() {
        // 900GB total, 500GB free → plenty of room; the "disk is X% full"
        // urgent signal must not fire. The plain biggest-category insight
        // still can (its reasoning leads with the category name), but it
        // never uses the urgent "Your disk is … full — only … free" framing.
        let pressure = DiskPressure(totalBytes: 900_000_000_000, freeBytes: 500_000_000_000)
        let snapshot = SystemSnapshot(
            categories: [safeCategory(bytes: 5_000_000_000)],
            memory: nil,
            processes: [],
            diskPressure: pressure,
            launchItems: nil
        )
        let insights = DeterministicInsights.from(snapshot)
        let urgent = insights.first { $0.reasoning.contains("disk is") && $0.reasoning.contains("full") }
        #expect(urgent == nil)
    }

    @Test func heavyStartupIsObserveOnly() {
        // 15 login items crosses the >=12 threshold. The insight must exist
        // and its action must be .observe — never a destructive path.
        let items = (0..<15).map(makeLaunchItem)
        let snapshot = SystemSnapshot(
            categories: [],
            memory: nil,
            processes: [],
            diskPressure: nil,
            launchItems: items
        )
        let insights = DeterministicInsights.from(snapshot)
        let startup = insights.first { $0.kind == .processes }
        #expect(startup != nil)
        #expect(startup?.action == .observe)
    }

    @Test func fewLoginItemsNoStartupInsight() {
        // Under the threshold — no startup nudge.
        let items = (0..<4).map(makeLaunchItem)
        let snapshot = SystemSnapshot(
            categories: [],
            memory: nil,
            processes: [],
            diskPressure: nil,
            launchItems: items
        )
        let insights = DeterministicInsights.from(snapshot)
        #expect(insights.filter { $0.kind == .processes }.isEmpty)
    }
}

/// Direct unit tests for the DiskPressure probe's math — no filesystem
/// involved, just the computed properties.
@Suite("DiskPressure math")
struct DiskPressureMathTests {
    @Test func usedFractionIsOneMinusFreeOverTotal() {
        let p = DiskPressure(totalBytes: 1_000, freeBytes: 250)
        #expect(p.usedFraction == 0.75)
    }

    @Test func zeroTotalIsSafe() {
        let p = DiskPressure(totalBytes: 0, freeBytes: 0)
        #expect(p.usedFraction == 0)
        #expect(!p.isAvailable)
    }
}
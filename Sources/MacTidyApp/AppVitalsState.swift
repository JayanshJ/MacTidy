import Foundation
import Observation
import CoreKit

enum MenuBarReadout: String, CaseIterable, Identifiable {
    case iconOnly
    case freeSpace
    case cpu
    case memory
    case battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .freeSpace: "Free disk space"
        case .cpu: "CPU usage"
        case .memory: "Memory pressure"
        case .battery: "Battery"
        }
    }
}

@MainActor
@Observable
final class AppVitalsState {
    private static let readoutKey = "MacTidy.menuBarReadout"

    var snapshot: SystemVitals.Snapshot?
    var diskPressure: DiskPressure?
    var memoryPressure: MemoryPressureLevel?

    var menuBarReadout: MenuBarReadout = MenuBarReadout(
        rawValue: UserDefaults.standard.string(forKey: readoutKey) ?? ""
    ) ?? .iconOnly {
        didSet {
            UserDefaults.standard.set(menuBarReadout.rawValue, forKey: Self.readoutKey)
            restartLoopIfNeeded()
        }
    }

    private var previousTicks: SystemVitals.CPUTicks?
    private var refreshing = false
    private var loopTask: Task<Void, Never>?

    func start() {
        guard !SnapshotHarness.isActive, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let interval: Duration = self.menuBarReadout == .iconOnly ? .seconds(30) : .seconds(5)
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    func cancel() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func restartLoopIfNeeded() {
        guard loopTask != nil else { return }
        cancel()
        start()
    }

    func refresh() async {
        guard !refreshing, !SnapshotHarness.isActive else { return }
        refreshing = true
        defer { refreshing = false }

        let prev = previousTicks
        let result = await Task.detached(priority: .utility) {
            var baseTicks = prev
            if baseTicks == nil {
                baseTicks = SystemVitals.CPUTicks.read()
                try? await Task.sleep(for: .milliseconds(250))
            }
            let sampled = SystemVitals.sample(previousTicks: baseTicks)
            let disk = DiskPressure.current()
            let mem = MemoryPressure.currentLevel()
            return (sampled.snapshot, sampled.ticks, disk, mem)
        }.value

        snapshot = result.0
        previousTicks = result.1
        diskPressure = result.2
        memoryPressure = result.3
    }

    func menuBarText(appMemoryPressure: MemoryPressureLevel?) -> String? {
        switch menuBarReadout {
        case .iconOnly:
            return nil
        case .freeSpace:
            guard let diskPressure, diskPressure.isAvailable else { return nil }
            return diskPressure.freeBytes.formattedBytes
        case .cpu:
            guard let usage = snapshot?.cpu.usagePercent else { return nil }
            return "\(Int(usage.rounded()))%"
        case .memory:
            guard let level = appMemoryPressure ?? memoryPressure else { return nil }
            return level.displayName
        case .battery:
            guard let batt = snapshot?.battery else { return nil }
            return "\(batt.chargePercent)%"
        }
    }
}

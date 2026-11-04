import AppKit
import Observation
import CoreKit

@MainActor @Observable
final class AppMemoryState {
    var processes: [RunningProcess] = []
    var summary: ProcessScanner.MemorySummary?
    var pressure: MemoryPressureLevel?
    var activity = AppActivity()
    var history = AppMemoryHistory()
    private var refreshing = false
    var apps: [RunningAppMemory] { RunningAppMemory.grouped(processes) }
    var candidates: [RunningAppMemory] {
        MemoryAdvice.candidates(processes: processes, pressure: pressure,
                                swapBytes: summary?.swapUsedBytes ?? 0)
    }

    func observeActivity() {
        let running = NSWorkspace.shared.runningApplications
        let launches = Dictionary(running.compactMap { app -> (String, Date)? in
            guard let path = app.bundleURL?.path, let date = app.launchDate else { return nil }
            return (path, date)
        }, uniquingKeysWith: max)
        activity.observe(paths: running.compactMap { $0.bundleURL?.path },
                         frontmost: NSWorkspace.shared.frontmostApplication?.bundleURL?.path,
                         launchDates: launches)
    }

    func refresh() async {
        guard !refreshing, !SnapshotHarness.isActive else { return }
        refreshing = true
        defer { refreshing = false }
        observeActivity()
        let activity = activity
        let snapshot = await Task.detached(priority: .utility) {
            (ProcessScanner.scan(activity: activity), ProcessScanner.memorySummary(), MemoryPressure.currentLevel())
        }.value
        processes = snapshot.0; summary = snapshot.1; pressure = snapshot.2
        history.record(apps)
    }

    func run() async {
        guard !SnapshotHarness.isActive else { return }
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}

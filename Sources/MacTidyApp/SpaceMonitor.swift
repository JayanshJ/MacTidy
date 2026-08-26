import Foundation
import Observation
import CoreKit
import UserNotifications

/// Background space watcher. Runs a cheap subset scan (fast categories only —
/// never the full Downloads/dev-root walk) on a fixed cadence while the app
/// is alive, even with the main window closed, and posts a local notification
/// when reclaimable space crosses the user's sensitivity threshold. Growth-
/// gated so it can't spam: it only notifies again when the pileup grows by
/// at least 20% or 500 MB over the last notification.
@MainActor
@Observable
final class SpaceMonitor {
    /// Fast categories only: directory listings + shallow size sums, safe to
    /// run every few hours. Deliberately excludes bigFiles/nodeModules/
    /// rustTargets/devCaches/appSupport (deep walks) and iosBackups/simulator
    /// runtimes (rarely change).
    static let fastCategories: [CoreKit.Category] = [
        .oldInstallers, .xcodeDerivedData, .xcodeDeviceSupport,
        .simulatorCaches, .homebrewCache,
    ]

    static let intervalHours: Int = 6

    /// Whether pile-up alerts are on. Persisted; default on.
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "MacTidy.monitor.enabled") }
    }

    /// Notify when the quick-check total crosses this many bytes.
    var thresholdBytes: Int64 {
        didSet { UserDefaults.standard.set(thresholdBytes, forKey: "MacTidy.monitor.threshold") }
    }

    /// Latest quick-check results (fast categories only, non-empty ones).
    private(set) var latestResults: [CategoryResult] = []

    /// Sum of the latest quick-check. Distinct from the dashboard's full-scan
    /// total — the panel labels it as a quick check to stay honest.
    private(set) var reclaimableBytes: Int64 = 0

    private(set) var lastChecked: Date?
    private(set) var isChecking = false

    private var hasStarted = false
    /// The periodic loop task, kept so `cancel()` can stop it on app
    /// termination — otherwise the long `Task.sleep` keeps the process
    /// from settling and `NSApp.terminate` hangs for tens of seconds.
    private var loopTask: Task<Void, Never>?

    init() {
        self.notificationsEnabled = UserDefaults.standard.object(forKey: "MacTidy.monitor.enabled") as? Bool ?? true
        self.thresholdBytes = UserDefaults.standard.object(forKey: "MacTidy.monitor.threshold") as? Int64 ?? 1_073_741_824
    }

    /// Starts the periodic loop exactly once per process, regardless of how
    /// many surfaces ask for it (window, menu bar panel).
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        loopTask = Task { await loop() }
    }

    /// Cancels the periodic loop so the app can terminate promptly. Called
    /// from `AppDelegate.applicationWillTerminate`. A sleeping `Task.sleep`
    /// doesn't block `NSApp.terminate` on its own, but an unstructured Task
    /// keeps the cooperative run loop alive until it settles; cancelling
    /// here lets termination return in seconds instead of tens of seconds.
    func cancel() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            if notificationsEnabled, FullDiskAccess.isGranted {
                await checkNow()
            }
            try? await Task.sleep(for: .seconds(Self.intervalHours * 3600))
        }
    }

    /// Runs one quick check and posts a notification when warranted.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let scanner = CategoryScanner()
        var results: [CategoryResult] = []
        for category in Self.fastCategories {
            if Task.isCancelled { return }
            let result = await scanner.scan(category)
            if !result.items.isEmpty { results.append(result) }
        }
        let total = results.reduce(0) { $0 + $1.totalBytes }
        latestResults = results.sorted { $0.totalBytes > $1.totalBytes }
        reclaimableBytes = total
        lastChecked = Date()

        if notificationsEnabled { maybeNotify(total: total) }
    }

    /// Only fires when above threshold AND grown meaningfully since the last
    /// alert — so a static 1.1 GB pile doesn't nag every six hours.
    private func maybeNotify(total: Int64) {
        let key = "MacTidy.monitor.lastNotified"
        let last = UserDefaults.standard.object(forKey: key) as? Int64 ?? 0
        guard total >= thresholdBytes,
              total - last >= max(536_870_912, Int64(Double(total) * 0.2)) else { return }
        UserDefaults.standard.set(total, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = "MacTidy found \(total.formattedBytes) of reclaimable space"
        content.body = "Caches and old downloads have piled up. Open MacTidy to review what's safe to clear."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.mactidy.space-pileup", content: content, trigger: nil
        )
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if granted { try? await center.add(request) }
            case .authorized, .provisional:
                try? await center.add(request)
            default:
                break
            }
        }
    }
}

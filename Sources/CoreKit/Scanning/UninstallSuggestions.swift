import Foundation

/// An installed app that looks forgotten but keeps a lot of data: removing the
/// app is a better answer than picking through its folder.
public struct UninstallSuggestion: Identifiable, Sendable, Hashable {
    public let app: InstalledApp
    /// What the app keeps in Application Support.
    public let dataBytes: Int64
    public let lastUsed: Date
    public var id: String { app.id }

    /// "Not opened since 4 months ago" reads badly, so this is just the age.
    public func unusedLabel(now: Date = Date()) -> String {
        "Not opened for \(AppUninstaller.lastUsedLabel(for: lastUsed, now: now).replacingOccurrences(of: " ago", with: ""))"
    }
}

/// Deterministic, no AI. Leads to the Uninstaller; it never trashes anything.
public enum UninstallSuggestions {
    static let minimumUnusedDays = 90
    static let minimumDataBytes: Int64 = 500 * 1024 * 1024

    /// Biggest data first. An app is left out unless every signal agrees:
    /// not Apple's, a known identifier, not running, a last-used date
    /// (Spotlight not knowing isn't the same as unused) at least 90 days old,
    /// and no file directly in its data folders changed in those 90 days.
    /// Background apps and apps started from a shell don't always update the
    /// last-used date, but they do write to their folders.
    public static func suggestions(
        for footprints: [AppFootprint],
        runningBundleIDs: Set<String>,
        now: Date = Date(),
        dataLastChanged: (URL) -> Date?
    ) -> [UninstallSuggestion] {
        let cutoff = now.addingTimeInterval(-Double(minimumUnusedDays) * 86_400)
        return footprints.compactMap { footprint -> UninstallSuggestion? in
            let app = footprint.app
            guard !app.isApple, let id = app.bundleID, !id.isEmpty, !runningBundleIDs.contains(id),
                  let lastUsed = app.lastUsedDate, lastUsed <= cutoff else { return nil }
            let data = footprint.paths.filter { $0.bucket == .appSupport }
            let bytes = data.reduce(0) { $0 + $1.sizeBytes }
            guard bytes >= minimumDataBytes,
                  !data.contains(where: { dataLastChanged($0.url).map { $0 > cutoff } ?? false }) else { return nil }
            return UninstallSuggestion(app: app, dataBytes: bytes, lastUsed: lastUsed)
        }
        .sorted { $0.dataBytes > $1.dataBytes }
    }

    /// The same, reading each data folder's dates from disk.
    public static func suggestions(for footprints: [AppFootprint], runningBundleIDs: Set<String>) -> [UninstallSuggestion] {
        suggestions(for: footprints, runningBundleIDs: runningBundleIDs,
                    dataLastChanged: AppSupportScanner.newestModification(of:))
    }
}

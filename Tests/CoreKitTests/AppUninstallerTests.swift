import Foundation
import Testing
@testable import CoreKit

/// `AppUninstaller` orphan detection + non-file actions. The leftover scan
/// runs against a throwaway home (via the internal `home:` entry point) so we
/// can assert exactly which paths are found and — critically — that decoys
/// are NOT swept up by the bundle-id matching rules.
@Suite("AppUninstaller")
struct AppUninstallerTests {
    private let id = "com.example.testapp"

    /// Builds a temp home with the standard leftover layout for `id`, plus
    /// decoys that must be rejected by the matching rules.
    private func makeFakeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mactidy-uninstaller-\(UUID().uuidString)")
        let library = home.appending(path: "Library")
        let fm = FileManager.default

        // Real leftovers that SHOULD be found.
        let real = [
            "Application Support/\(id)",
            "Caches/\(id)",
            "Preferences/\(id).plist",
            "Saved Application State/\(id).savedState",
            "Containers/\(id)",
            "Logs/\(id)",
            "LaunchAgents/\(id).plist",
            "HTTPStorages/\(id)",
            "WebKit/\(id)",
            "Preferences/ByHost/\(id).A1B2C3D4-5678-90AB-CDEF-1234567890AB.plist",
            "Logs/DiagnosticReports/\(id)-2024-01-01.crash",
            "Group Containers/ABCDE12345.\(id)",
        ]
        // Decoys that must NOT be found.
        let decoys = [
            // Substring group container: contains id but not a ".<id>" suffix.
            "Group Containers/ABCDE12345.\(id).sharedhelper",
            // Different bundle id sharing a prefix word.
            "Application Support/com.example.testapp-helper",
            // ByHost for a different app.
            "Preferences/ByHost/com.other.app.UUID.plist",
        ]
        for rel in real + decoys {
            let url = library.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if rel.hasSuffix(".plist") || rel.hasSuffix(".crash") || rel.hasSuffix(".savedState") {
                try Data("x".utf8).write(to: url)
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url.appending(path: "sentinel"))
            }
        }
        return home
    }

    @Test func findsAllLeftoverCategoriesAndRejectsDecoys() async throws {
        let home = try makeFakeHome()
        let app = InstalledApp(
            url: home.appending(path: "Applications/TestApp.app"),
            name: "TestApp",
            bundleID: id,
            sizeBytes: 1024
        )
        let leftovers = await AppUninstaller.leftovers(for: app, home: home)
        let names = Set(leftovers.map { $0.url.lastPathComponent })

        // Every real leftover category is found.
        #expect(names.contains(id))                              // dir + .plist base
        #expect(names.contains("\(id).plist"))
        #expect(names.contains("\(id).savedState"))
        #expect(names.contains("\(id).A1B2C3D4-5678-90AB-CDEF-1234567890AB.plist"))
        #expect(names.contains("\(id)-2024-01-01.crash"))
        #expect(names.contains("ABCDE12345.\(id)"))              // group container

        // Decoys are rejected — the safety regression.
        #expect(!names.contains("ABCDE12345.\(id).sharedhelper"))
        #expect(!names.contains("com.example.testapp-helper"))
        #expect(!names.contains("com.other.app.UUID.plist"))

        // Count: 9 standard + 1 ByHost + 1 crash + 1 group container = 12.
        #expect(leftovers.count == 12)
    }

    @Test func actionsForNonAppleAppIncludeTCCAndLaunchServices() {
        let app = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Foo.app"),
            name: "Foo",
            bundleID: "com.example.foo",
            sizeBytes: 0
        )
        let actions = AppUninstaller.actions(for: app)
        #expect(actions.count == 2)
        #expect(actions.contains { $0.kind == .tccReset })
        #expect(actions.contains { $0.kind == .lsregister })
        #expect(actions.first { $0.kind == .tccReset }?.target == "com.example.foo")
        #expect(actions.first { $0.kind == .lsregister }?.target == "/Applications/Foo.app")
    }

    @Test func actionsForAppleAppIsEmpty() {
        let app = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Notes.app"),
            name: "Notes",
            bundleID: "com.apple.Notes",
            sizeBytes: 0
        )
        #expect(AppUninstaller.actions(for: app).isEmpty)
    }

    // MARK: - Last-used label

    @Test func lastUsedLabelNeverForNil() {
        #expect(AppUninstaller.lastUsedLabel(for: nil, now: Date()) == "Never")
    }

    @Test func lastUsedLabelJustNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let date = now.addingTimeInterval(-30)   // 30s ago
        #expect(AppUninstaller.lastUsedLabel(for: date, now: now) == "Just now")
    }

    @Test func lastUsedLabelMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let date = now.addingTimeInterval(-5 * 60)  // 5 min ago
        #expect(AppUninstaller.lastUsedLabel(for: date, now: now) == "5 min ago")
    }

    @Test func lastUsedLabelHours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let date = now.addingTimeInterval(-3 * 3600)  // 3 hr ago
        #expect(AppUninstaller.lastUsedLabel(for: date, now: now) == "3 hr ago")
    }

    @Test func lastUsedLabelDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let date = now.addingTimeInterval(-12 * 86400)  // 12 days ago
        #expect(AppUninstaller.lastUsedLabel(for: date, now: now) == "12 days ago")
    }

    @Test func lastUsedLabelMonthsAndYears() {
        // Build dates by calendar so month/year arithmetic is deterministic
        // regardless of the test machine's timezone or DST.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 26))!

        let eightMonthsAgo = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        #expect(AppUninstaller.lastUsedLabel(for: eightMonthsAgo, now: now) == "7 months ago")

        let twoYearsAgo = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        #expect(AppUninstaller.lastUsedLabel(for: twoYearsAgo, now: now) == "2 years ago")
    }

    @Test func lastUsedLabelClockSkewTreatedAsNever() {
        // A future date (clock skew) should not produce a negative label.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = now.addingTimeInterval(60)
        #expect(AppUninstaller.lastUsedLabel(for: future, now: now) == "Never")
    }

    // MARK: - By-last-opened ranking

    @Test func neverOpenedSortsFirst() {
        let never = InstalledApp(url: URL(fileURLWithPath: "/A"),
                                  name: "A", bundleID: nil, sizeBytes: 100, lastUsedDate: nil)
        let used = InstalledApp(url: URL(fileURLWithPath: "/B"),
                                 name: "B", bundleID: nil, sizeBytes: 500,
                                 lastUsedDate: Date(timeIntervalSince1970: 1_000_000))
        // never before used, regardless of size.
        #expect(AppUninstaller.byLastOpened(never, used) == true)
        #expect(AppUninstaller.byLastOpened(used, never) == false)
    }

    @Test func oldestFirstAmongUsed() {
        let older = InstalledApp(url: URL(fileURLWithPath: "/A"),
                                  name: "A", bundleID: nil, sizeBytes: 100,
                                  lastUsedDate: Date(timeIntervalSince1970: 1_000_000))
        let newer = InstalledApp(url: URL(fileURLWithPath: "/B"),
                                  name: "B", bundleID: nil, sizeBytes: 500,
                                  lastUsedDate: Date(timeIntervalSince1970: 2_000_000))
        #expect(AppUninstaller.byLastOpened(older, newer) == true)
        #expect(AppUninstaller.byLastOpened(newer, older) == false)
    }

    @Test func sizeTiebreaksEqualLastUsed() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let small = InstalledApp(url: URL(fileURLWithPath: "/A"),
                                  name: "A", bundleID: nil, sizeBytes: 100, lastUsedDate: date)
        let big = InstalledApp(url: URL(fileURLWithPath: "/B"),
                                name: "B", bundleID: nil, sizeBytes: 500, lastUsedDate: date)
        // Same date → bigger sorts first (tiebreak).
        #expect(AppUninstaller.byLastOpened(big, small) == true)
        #expect(AppUninstaller.byLastOpened(small, big) == false)
    }

    @Test func sizeTiebreaksBothNeverOpened() {
        let small = InstalledApp(url: URL(fileURLWithPath: "/A"),
                                  name: "A", bundleID: nil, sizeBytes: 100, lastUsedDate: nil)
        let big = InstalledApp(url: URL(fileURLWithPath: "/B"),
                               name: "B", bundleID: nil, sizeBytes: 500, lastUsedDate: nil)
        #expect(AppUninstaller.byLastOpened(big, small) == true)
        #expect(AppUninstaller.byLastOpened(small, big) == false)
    }
}
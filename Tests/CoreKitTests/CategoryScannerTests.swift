import Foundation
import Testing
@testable import CoreKit

@Suite("CategoryScanner new categories")
struct CategoryScannerTests {
    /// Builds a throwaway fake home directory so scans are hermetic.
    func makeFakeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func devCachesFindsKnownToolCaches() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        try fm.createDirectory(at: home.appending(path: ".npm/_cacache"),
                               withIntermediateDirectories: true)
        try Data(count: 4096).write(to: home.appending(path: ".npm/_cacache/blob.bin"))
        try fm.createDirectory(at: home.appending(path: ".cargo/registry/cache"),
                               withIntermediateDirectories: true)
        try Data(count: 8192).write(to: home.appending(path: ".cargo/registry/cache/crate.crate"))
        // Empty gradle dir → zero bytes → must not be listed.
        try fm.createDirectory(at: home.appending(path: ".gradle/caches"),
                               withIntermediateDirectories: true)

        let result = await CategoryScanner(home: home).scan(.devCaches)

        #expect(result.items.count == 2)
        let labels = Set(result.items.compactMap(\.detail))
        #expect(labels == ["npm cache", "Cargo registry"])
        #expect(result.totalBytes > 0)
        #expect(Category.devCaches.isPreselectable)
    }

    @Test func devCachesFindsGoAndMaven() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        try fm.createDirectory(at: home.appending(path: "go/pkg/mod/cache"),
                               withIntermediateDirectories: true)
        try Data(count: 4096).write(to: home.appending(path: "go/pkg/mod/cache/mod.zip"))
        try fm.createDirectory(at: home.appending(path: ".m2/repository/com"),
                               withIntermediateDirectories: true)
        try Data(count: 2048).write(to: home.appending(path: ".m2/repository/com/artifact.jar"))

        let result = await CategoryScanner(home: home).scan(.devCaches)
        let labels = Set(result.items.compactMap(\.detail))
        #expect(labels.contains("Go module cache"))
        #expect(labels.contains("Maven repository"))
    }

    @Test func devCachesFindsBunXdgDeno() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        try fm.createDirectory(at: home.appending(path: ".bun/install/cache"),
                               withIntermediateDirectories: true)
        try Data(count: 4096).write(to: home.appending(path: ".bun/install/cache/pkg.tar"))
        try fm.createDirectory(at: home.appending(path: ".cache/pip"),
                               withIntermediateDirectories: true)
        try Data(count: 8192).write(to: home.appending(path: ".cache/pip/wheel.whl"))
        try fm.createDirectory(at: home.appending(path: ".deno/gen"),
                               withIntermediateDirectories: true)
        try Data(count: 2048).write(to: home.appending(path: ".deno/gen/file.ts.js"))

        let result = await CategoryScanner(home: home).scan(.devCaches)
        let labels = Set(result.items.compactMap(\.detail))
        #expect(labels.contains("Bun cache"))
        #expect(labels.contains("XDG cache (~/.cache)"))
        #expect(labels.contains("Deno cache"))
        // ~8KB across three caches (XDG is counted at its root, so its child
        // wheel bytes are rolled into the XDG entry — not double-listed).
        #expect(result.items.count == 3)
    }

    @Test func simulatorRuntimesListsDownloadedRuntimes() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let images = home.appending(path: "Library/Developer/CoreSimulator/Images")
        let runtime = images.appending(path: "iOS 17.0.simruntime")
        try fm.createDirectory(at: runtime.appending(path: "Contents"), withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: runtime.appending(path: "Contents/CoreSimulator.dmg"))

        let result = await CategoryScanner(home: home).scan(.simulatorRuntimes)
        #expect(result.items.count == 1)
        #expect(result.items.first?.url.lastPathComponent == "iOS 17.0.simruntime")
        #expect(result.totalBytes > 0)
        #expect(!Category.simulatorRuntimes.isPreselectable)
    }

    @Test func appSupportListsBiggestFoldersFirst() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let support = home.appending(path: "Library/Application Support")
        try fm.createDirectory(at: support.appending(path: "Slack"), withIntermediateDirectories: true)
        try Data(count: 80_000).write(to: support.appending(path: "Slack/cache.db"))
        try fm.createDirectory(at: support.appending(path: "TinyApp"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: support.appending(path: "TinyApp/config.json"))

        let result = await CategoryScanner(home: home).scan(.appSupport)
        #expect(result.items.count == 2)
        #expect(result.items.first?.url.lastPathComponent == "Slack")
        #expect(!Category.appSupport.isPreselectable)
    }

    @Test func iosBackupsReadsDeviceNameAndDate() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let backup = home.appending(
            path: "Library/Application Support/MobileSync/Backup/00008101-000A1B2C3D4E5F")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: backup.appending(path: "Manifest.db"))
        let backupDate = Date(timeIntervalSince1970: 1_700_000_000)
        let info: [String: Any] = ["Device Name": "Jayansh's iPhone",
                                   "Last Backup Date": backupDate]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: backup.appending(path: "Info.plist"))

        let result = await CategoryScanner(home: home).scan(.iosBackups)

        #expect(result.items.count == 1)
        let item = try #require(result.items.first)
        #expect(item.detail == "Jayansh's iPhone")
        #expect(item.lastModified == backupDate)
        #expect(item.sizeBytes > 0)
        // Device backups must never be bulk-preselected.
        #expect(!Category.iosBackups.isPreselectable)
    }
}

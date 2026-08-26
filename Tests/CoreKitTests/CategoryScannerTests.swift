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

    // MARK: - new build-dir categories (Pods, SwiftPM .build, Gradle build, Python)

    /// Builds a fake home + a fake dev root (so `buildDirs` has somewhere to
    /// walk), returns the dev root URL. The scanner is constructed with this
    /// as the sole dev root.
    private func makeFakeHomeWithDevRoot() throws -> (home: URL, devRoot: URL) {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let devRoot = home.appending(path: "Developer")
        try FileManager.default.createDirectory(at: devRoot, withIntermediateDirectories: true)
        return (home, devRoot)
    }

    /// Writes a small file into `dir` so its allocated size is non-zero (a
    /// bare empty dir would be filtered out by the `size > 0` guards).
    private func seed(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: dir.appending(path: "blob.bin"))
    }

    @Test func podDirsFindsPodsWithPodfile() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        let project = devRoot.appending(path: "iOSApp")
        try seed(project.appending(path: "Pods/Firebase"))
        try Data("x".utf8).write(to: project.appending(path: "Podfile"))

        // A `Pods` dir with no sibling Podfile must NOT be listed.
        let decoy = devRoot.appending(path: "Decoy")
        try seed(decoy.appending(path: "Pods/something"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.podDirs)
        #expect(result.items.count == 1)
        #expect(result.items.first?.detail == "iOSApp")
        #expect(result.items.first?.category == .podDirs)
        #expect(Category.podDirs.isPreselectable)
    }

    @Test func swiftBuildDirsFindsBuildWithPackageSwift() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        let project = devRoot.appending(path: "SwiftLib")
        try seed(project.appending(path: ".build/artifacts"))
        try Data("x".utf8).write(to: project.appending(path: "Package.swift"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.swiftBuildDirs)
        #expect(result.items.count == 1)
        #expect(result.items.first?.detail == "SwiftLib")
        #expect(Category.swiftBuildDirs.isPreselectable)
    }

    @Test func gradleBuildDirsAcceptsKotlinAndGroovyMarkers() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        // Kotlin DSL marker.
        let kotlin = devRoot.appending(path: "KotlinApp")
        try seed(kotlin.appending(path: "build/classes"))
        try Data("x".utf8).write(to: kotlin.appending(path: "build.gradle.kts"))
        // Groovy marker.
        let groovy = devRoot.appending(path: "GroovyApp")
        try seed(groovy.appending(path: "build/libs"))
        try Data("x".utf8).write(to: groovy.appending(path: "build.gradle"))
        // A `build` dir with no gradle marker must NOT be listed.
        let decoy = devRoot.appending(path: "Decoy")
        try seed(decoy.appending(path: "build/output"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.gradleBuildDirs)
        #expect(result.items.count == 2)
        let names = Set(result.items.compactMap(\.detail))
        #expect(names == ["KotlinApp", "GroovyApp"])
        #expect(Category.gradleBuildDirs.isPreselectable)
    }

    @Test func pythonCachesFindsPycacheAndMarkeredVenv() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        // __pycache__ anywhere under a project is always picked up.
        let pyProject = devRoot.appending(path: "PyProj")
        try seed(pyProject.appending(path: "src/__pycache__"))
        // .venv with a sibling pyproject.toml → listed.
        try seed(pyProject.appending(path: ".venv/lib"))
        try Data("x".utf8).write(to: pyProject.appending(path: "pyproject.toml"))

        // A bare .venv with no project marker must NOT be listed.
        let decoy = devRoot.appending(path: "Decoy")
        try seed(decoy.appending(path: ".venv/lib"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.pythonCaches)
        // One __pycache__ + one .venv from PyProj; Decoy's .venv excluded.
        #expect(result.items.count == 2)
        #expect(result.items.allSatisfy { $0.category == .pythonCaches })
        // Python caches is suggest-only (because of .venv).
        #expect(!Category.pythonCaches.isPreselectable)
    }

    // MARK: - 1.8 scopes: JS build dirs, container caches, Xcode Archives, Mail

    @Test func jsBuildDirsFindsNextAndNuxt() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        let next = devRoot.appending(path: "NextApp")
        try seed(next.appending(path: ".next/static"))
        try Data("x".utf8).write(to: next.appending(path: "package.json"))
        let nuxt = devRoot.appending(path: "NuxtApp")
        try seed(nuxt.appending(path: ".nuxt/dist"))
        try Data("x".utf8).write(to: nuxt.appending(path: "package.json"))
        // A .next dir with no sibling package.json → not listed.
        let decoy = devRoot.appending(path: "Decoy")
        try seed(decoy.appending(path: ".next/static"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.jsBuildDirs)
        #expect(result.items.count == 2)
        let names = Set(result.items.compactMap(\.detail))
        #expect(names == ["NextApp", "NuxtApp"])
        #expect(Category.jsBuildDirs.isPreselectable)
    }

    @Test func containerCachesFindsAppCaches() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let caches = home.appending(path: "Library/Containers/com.example.app/Data/Library/Caches")
        try seed(caches.appending(path: "BlobCache"))
        // Mail's container caches must be skipped (mailDownloads covers it).
        let mailCaches = home.appending(path: "Library/Containers/com.apple.Mail/Data/Library/Caches")
        try seed(mailCaches.appending(path: "Attachments"))

        let result = await CategoryScanner(home: home).scan(.containerCaches)
        #expect(result.items.count == 1)
        #expect(result.items.first?.detail == "com.example.app")
        #expect(Category.containerCaches.isPreselectable)
    }

    @Test func xcodeArchivesListed() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        // Real Xcode layout: Archives/<date>/<App>.xcarchive. The scan
        // descends the date folder and surfaces each .xcarchive bundle.
        let archive = home.appending(path: "Library/Developer/Xcode/Archives/2026-08-26/MyApp.xcarchive")
        try seed(archive.appending(path: "dSYMs"))
        // Must be suggest-only — symbols for past uploads.
        #expect(!Category.xcodeArchives.isPreselectable)

        let result = await CategoryScanner(home: home).scan(.xcodeArchives)
        #expect(result.items.count == 1)
        #expect(result.items.first?.url.lastPathComponent == "MyApp.xcarchive")
    }

    @Test func mailDownloadsListed() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let downloads = home.appending(path: "Library/Containers/com.apple.Mail/Data/Library/Mail Downloads")
        try seed(downloads.appending(path: "attachment.pdf"))

        let result = await CategoryScanner(home: home).scan(.mailDownloads)
        #expect(result.items.count == 1)
        #expect(Category.mailDownloads.isPreselectable)
    }
}

/// Time Machine snapshot parsing — `tmutil listlocalsnapshots` output comes
/// in two line shapes depending on macOS version; both must parse.
@Suite("TimeMachineScanner")
struct TimeMachineScannerTests {
    @Test func parsesSnapshotDateForm() {
        let stdout = """
        Snapshot Date: 2026-08-26-002000
        Snapshot Date: 2026-08-25-120000
        """
        let snaps = TimeMachineScanner.parse(stdout)
        #expect(snaps.count == 2)
        #expect(snaps[0].date == "2026-08-26-002000")
        #expect(snaps[0].name == "com.apple.TimeMachine.2026-08-26-002000")
    }

    @Test func parsesComApplePrefixForm() {
        let stdout = """
        com.apple.TimeMachine.2026-08-26-002000
        com.apple.TimeMachine.2026-08-25-120000
        """
        let snaps = TimeMachineScanner.parse(stdout)
        #expect(snaps.count == 2)
        #expect(snaps[1].date == "2026-08-25-120000")
        #expect(snaps[1].name == "com.apple.TimeMachine.2026-08-25-120000")
    }

    @Test func parseIgnoresBlankAndJunkLines() {
        let stdout = """

        tmutil: scanning...
        Snapshot Date: 2026-08-26-002000

        """
        let snaps = TimeMachineScanner.parse(stdout)
        #expect(snaps.count == 1)
    }

    @Test func deleteSnapshotActionCommandsUseDeletelocalsnapshots() {
        let snap = TMSnapshot(name: "com.apple.TimeMachine.2026-08-26-002000",
                              date: "2026-08-26-002000")
        let action = DeleteSnapshotAction(snapshot: snap)
        #expect(action.commandSummary == "tmutil deletelocalsnapshots 2026-08-26-002000")
        #expect(action.reversible == false)
        // We don't know per-snapshot size → honest zero.
        #expect(action.estimatedBytes == 0)
    }
}

/// Docker builder cache parsing — `docker builder df` reclaimable size.
@Suite("DockerBuilderCache")
struct DockerBuilderCacheTests {
    @Test func parsesBuildCacheReclaimable() {
        let stdout = """
        TYPE            TOTAL   ACTIVE  SIZE        RECLAIMABLE
        Images          10      5       2.3GB      800MB
        Containers      3       1       100MB      50MB
        Build Cache     120     10      1.5GB      1.2GB
        Local Volumes    0      0       0B         0B
        """
        let bytes = DockerBuilderCache.parseReclaimableBytes(stdout)
        // RECLAIMABLE column (1.2GB) = 1.2 billion bytes.
        #expect(bytes == 1_200_000_000)
    }

    @Test func fallsBackToSizeColumnWhenNoReclaimable() {
        // If RECLAIMABLE can't be parsed, fall back to SIZE (column 4).
        let stdout = "Build Cache     120     10      1.5GB      ???"
        let bytes = DockerBuilderCache.parseReclaimableBytes(stdout)
        #expect(bytes == 1_500_000_000)
    }

    @Test func returnsNilWhenNoBuildCacheRow() {
        #expect(DockerBuilderCache.parseReclaimableBytes("Images  10  5  2.3GB  800MB") == nil)
        #expect(DockerBuilderCache.parseReclaimableBytes("") == nil)
    }

    @Test func pruneActionCommandIsBuilderPruneF() {
        let action = DockerBuilderPruneAction(estimatedBytes: 1_200_000_000)
        #expect(action.commandSummary == "docker builder prune -f")
        #expect(action.reversible == false)
        #expect(action.estimatedBytes == 1_200_000_000)
    }
}

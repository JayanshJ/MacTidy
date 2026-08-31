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

    // MARK: - 1.9 scopes: Maven, PHP, Flutter, Unity, Android images, screenshots, Python extras

    @Test func mavenTargetFindsTargetWithPom() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        let project = devRoot.appending(path: "MvnApp")
        try seed(project.appending(path: "target/classes"))
        try Data("x".utf8).write(to: project.appending(path: "pom.xml"))
        // A `target` dir with no sibling pom.xml must NOT be listed.
        let decoy = devRoot.appending(path: "Decoy")
        try seed(decoy.appending(path: "target/output"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.mavenTarget)
        #expect(result.items.count == 1)
        #expect(result.items.first?.detail == "MvnApp")
        #expect(Category.mavenTarget.isPreselectable)
    }

    @Test func phpVendorFindsVendorWithComposer() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        let project = devRoot.appending(path: "PhpApp")
        try seed(project.appending(path: "vendor/laravel"))
        try Data("x".utf8).write(to: project.appending(path: "composer.json"))
        let decoy = devRoot.appending(path: "Decoy")
        try seed(decoy.appending(path: "vendor/generic"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.phpVendor)
        #expect(result.items.count == 1)
        #expect(result.items.first?.detail == "PhpApp")
        #expect(Category.phpVendor.isPreselectable)
    }

    @Test func flutterDartToolFindsDartToolWithPubspec() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        let project = devRoot.appending(path: "FlutterApp")
        try seed(project.appending(path: ".dart_tool/build"))
        try Data("x".utf8).write(to: project.appending(path: "pubspec.yaml"))
        let decoy = devRoot.appending(path: "Decoy")
        try seed(decoy.appending(path: ".dart_tool/build"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.flutterDartTool)
        #expect(result.items.count == 1)
        #expect(result.items.first?.detail == "FlutterApp")
        #expect(Category.flutterDartTool.isPreselectable)
    }

    @Test func unityLibraryRequiresProjectSettingsSibling() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        // Real Unity project: Library/ + sibling ProjectSettings/.
        let unity = devRoot.appending(path: "UnityGame")
        try seed(unity.appending(path: "Library/AssetCache"))
        try fm.createDirectory(at: unity.appending(path: "ProjectSettings"),
                               withIntermediateDirectories: true)
        // A `Library` dir with no sibling ProjectSettings must NOT be listed.
        let decoy = devRoot.appending(path: "Decoy")
        try seed(decoy.appending(path: "Library/junk"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.unityLibrary)
        #expect(result.items.count == 1)
        #expect(result.items.first?.detail == "UnityGame")
        #expect(!Category.unityLibrary.isPreselectable)
    }

    @Test func androidSystemImagesListsVariantLeaves() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        // sdk/system-images/<abi>/<api>/<variant>
        let variant = home.appending(path: "Library/Android/sdk/system-images/arm64-v8a/android-34/google_apis")
        try seed(variant.appending(path: "system.img"))

        let result = await CategoryScanner(home: home).scan(.androidSystemImages)
        #expect(result.items.count == 1)
        #expect(result.items.first?.detail == "arm64-v8a/android-34/google_apis")
        #expect(!Category.androidSystemImages.isPreselectable)
    }

    @Test func staleScreenshotsListsOldScreenshotsOnly() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let desktop = home.appending(path: "Desktop")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        // Old screenshot (>30 days) — listed.
        let old = desktop.appending(path: "Screenshot 2026-01-01 at 12.00.00.png")
        try Data(count: 4096).write(to: old)
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-40 * 86400)], ofItemAtPath: old.path)
        // Recent screenshot (<30 days) — NOT listed.
        let recent = desktop.appending(path: "Screen Shot 2026-08-26 at 09.00.00.png")
        try Data(count: 4096).write(to: recent)
        // Old non-screenshot — NOT listed.
        let doc = desktop.appending(path: "notes.txt")
        try Data(count: 4096).write(to: doc)
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-40 * 86400)], ofItemAtPath: doc.path)

        let result = await CategoryScanner(home: home).scan(.staleScreenshots)
        #expect(result.items.count == 1)
        #expect(result.items.first?.url.lastPathComponent.hasPrefix("Screenshot") == true)
        #expect(!Category.staleScreenshots.isPreselectable)
    }

    @Test func pythonCachesNowIncludesPytestToxIpynbCheckpoints() async throws {
        let fm = FileManager.default
        let (home, devRoot) = try makeFakeHomeWithDevRoot()
        defer { try? fm.removeItem(at: home) }

        let project = devRoot.appending(path: "PyProj")
        try seed(project.appending(path: "src/__pycache__"))
        try seed(project.appending(path: ".pytest_cache/v"))
        try seed(project.appending(path: ".tox/py39"))
        try seed(project.appending(path: "notebooks/.ipynb_checkpoints"))

        let result = await CategoryScanner(home: home, devRoots: [devRoot]).scan(.pythonCaches)
        // Four Python cache dirs, no marker needed for these.
        #expect(result.items.count == 4)
        #expect(result.items.allSatisfy { $0.category == .pythonCaches })
        // Still suggest-only because of .venv.
        #expect(!Category.pythonCaches.isPreselectable)
    }

    // MARK: - 1.11 new devCaches entries (CocoaPods, Ollama, Colima, VS Code, etc.)

    @Test func devCachesFindsCocoaPodsAndOllama() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        try fm.createDirectory(at: home.appending(path: ".cocoapods/repos"),
                               withIntermediateDirectories: true)
        try Data(count: 4096).write(to: home.appending(path: ".cocoapods/repos/specs.db"))
        try fm.createDirectory(at: home.appending(path: ".ollama/models/manifests"),
                               withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: home.appending(path: ".ollama/models/manifests/llama3"))

        let result = await CategoryScanner(home: home).scan(.devCaches)
        let labels = Set(result.items.compactMap(\.detail))
        #expect(labels.contains("CocoaPods cache"))
        #expect(labels.contains("Ollama models"))
    }

    @Test func devCachesFindsColimaAndLima() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        try fm.createDirectory(at: home.appending(path: ".colima/default"),
                               withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: home.appending(path: ".colima/default/colima.img"))
        try fm.createDirectory(at: home.appending(path: ".lima/default"),
                               withIntermediateDirectories: true)
        try Data(count: 80_000).write(to: home.appending(path: ".lima/default/disk.img"))

        let result = await CategoryScanner(home: home).scan(.devCaches)
        let labels = Set(result.items.compactMap(\.detail))
        #expect(labels.contains("Colima VM disk"))
        #expect(labels.contains("Lima VM disk"))
    }

    @Test func devCachesFindsVSCodeExtensions() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        try fm.createDirectory(at: home.appending(path: ".vscode/extensions/ms-python.python"),
                               withIntermediateDirectories: true)
        try Data(count: 40_000).write(to: home.appending(path: ".vscode/extensions/ms-python.python/extension.vsixmanifest"))

        let result = await CategoryScanner(home: home).scan(.devCaches)
        let labels = Set(result.items.compactMap(\.detail))
        #expect(labels.contains("VS Code extensions"))
    }

    // MARK: - 1.11 new categories (simulatorDevices, systemLogs, crashReports, etc.)

    @Test func simulatorDevicesListsPerDeviceData() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let devices = home.appending(path: "Library/Developer/CoreSimulator/Devices")
        let device = devices.appending(path: "00008101-000A1B2C3D4E5F/data")
        try seed(device.appending(path: "Containers"))

        let result = await CategoryScanner(home: home).scan(.simulatorDevices)
        #expect(result.items.count == 1)
        #expect(result.totalBytes > 0)
        #expect(!Category.simulatorDevices.isPreselectable)
    }

    @Test func systemLogsListsPerAppLogFolders() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let logs = home.appending(path: "Library/Logs")
        try seed(logs.appending(path: "com.example.app"))
        try seed(logs.appending(path: "AnotherApp"))

        let result = await CategoryScanner(home: home).scan(.systemLogs)
        #expect(result.items.count == 2)
        #expect(result.totalBytes > 0)
        #expect(!Category.systemLogs.isPreselectable)
    }

    @Test func crashReportsListsCrashLogs() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let diag = home.appending(path: "Library/Logs/DiagnosticReports")
        try fm.createDirectory(at: diag, withIntermediateDirectories: true)
        try Data(count: 8192).write(to: diag.appending(path: "MyApp-2026-08-30-000000.ips"))

        let result = await CategoryScanner(home: home).scan(.crashReports)
        #expect(result.items.count == 1)
        #expect(result.totalBytes > 0)
        #expect(Category.crashReports.isPreselectable)
    }

    @Test func savedAppStateListsPerAppStateFiles() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let state = home.appending(path: "Library/Saved Application State")
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: state.appending(path: "com.example.app.savedState"))

        let result = await CategoryScanner(home: home).scan(.savedAppState)
        #expect(result.items.count == 1)
        #expect(result.totalBytes > 0)
        #expect(Category.savedAppState.isPreselectable)
    }

    @Test func httpStoragesListsPerAppHTTPStorage() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let http = home.appending(path: "Library/HTTPStorages")
        try seed(http.appending(path: "com.example.app"))
        try fm.createDirectory(at: http, withIntermediateDirectories: true)

        let result = await CategoryScanner(home: home).scan(.httpStorages)
        #expect(result.items.count == 1)
        #expect(result.totalBytes > 0)
        #expect(Category.httpStorages.isPreselectable)
    }

    @Test func groupContainersListsSharedAppData() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let groups = home.appending(path: "Library/Group Containers")
        try seed(groups.appending(path: "group.com.example.shared"))
        try fm.createDirectory(at: groups, withIntermediateDirectories: true)

        let result = await CategoryScanner(home: home).scan(.groupContainers)
        #expect(result.items.count == 1)
        #expect(result.totalBytes > 0)
        #expect(!Category.groupContainers.isPreselectable)
    }

    @Test func devCachesFindsFastlaneAndAndroidAndXcodeUserData() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        try fm.createDirectory(at: home.appending(path: ".fastlane/caches"),
                               withIntermediateDirectories: true)
        try Data(count: 4096).write(to: home.appending(path: ".fastlane/caches/metadata.json"))
        try fm.createDirectory(at: home.appending(path: ".android/avd/Pixel_6.avd"),
                               withIntermediateDirectories: true)
        try Data(count: 40_000).write(to: home.appending(path: ".android/avd/Pixel_6.avd/data.img"))
        try fm.createDirectory(at: home.appending(path: "Library/Developer/Xcode/UserData/Breakpoints"),
                               withIntermediateDirectories: true)
        try Data(count: 2048).write(to: home.appending(path: "Library/Developer/Xcode/UserData/Breakpoints/bplist.plist"))

        let result = await CategoryScanner(home: home).scan(.devCaches)
        let labels = Set(result.items.compactMap(\.detail))
        #expect(labels.contains("Fastlane cache"))
        #expect(labels.contains("Android AVD data"))
        #expect(labels.contains("Xcode UserData"))
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

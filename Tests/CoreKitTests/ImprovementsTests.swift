import Foundation
import Testing
@testable import CoreKit

@Suite("Stable ScanItem deterministic ID")
struct ScanItemDeterministicIDTests {
    @Test func sameURLProducesIdenticalDeterministicID() {
        let url = URL(fileURLWithPath: "/Users/test/Project/node_modules")
        let item1 = ScanItem(url: url, sizeBytes: 1000, isDirectory: true, category: .nodeModules)
        let item2 = ScanItem(url: url, sizeBytes: 2000, isDirectory: true, category: .nodeModules)

        #expect(item1.id == item2.id)
        #expect(item1.id == ScanItem.deterministicID(for: url))
    }

    @Test func differentURLsProduceDifferentIDs() {
        let url1 = URL(fileURLWithPath: "/Users/test/Project1/target")
        let url2 = URL(fileURLWithPath: "/Users/test/Project2/target")
        let item1 = ScanItem(url: url1, sizeBytes: 1000, isDirectory: true, category: .rustTargets)
        let item2 = ScanItem(url: url2, sizeBytes: 1000, isDirectory: true, category: .rustTargets)

        #expect(item1.id != item2.id)
    }

    @Test func canonicalPathResolutionNormalizesTrailingSlashes() {
        let url1 = URL(fileURLWithPath: "/Users/test/Cache/")
        let url2 = URL(fileURLWithPath: "/Users/test/Cache")

        #expect(ScanItem.deterministicID(for: url1) == ScanItem.deterministicID(for: url2))
    }

    @Test func explicitIDIsPreserved() {
        let customUUID = UUID()
        let item = ScanItem(
            id: customUUID,
            url: URL(fileURLWithPath: "/tmp/foo"),
            sizeBytes: 50,
            isDirectory: false
        )
        #expect(item.id == customUUID)
    }
}

@Suite("Recommendations suggest-only")
struct RecommendationsSuggestOnlyTests {
    @Test func suggestOnlyFiltersToSuggestOnlyCategories() {
        let safeCache = ScanItem(url: URL(fileURLWithPath: "/tmp/cache"), sizeBytes: 50_000_000,
                                 isDirectory: true, category: .userCaches)
        let bigFile = ScanItem(url: URL(fileURLWithPath: "/tmp/big.iso"), sizeBytes: 100_000_000,
                               isDirectory: false, category: .bigFiles)
        let appState = ScanItem(url: URL(fileURLWithPath: "/tmp/appState"), sizeBytes: 20_000_000,
                                isDirectory: true, category: .appSupport)

        let results = [
            CategoryResult(category: .userCaches, items: [safeCache]),
            CategoryResult(category: .bigFiles, items: [bigFile]),
            CategoryResult(category: .appSupport, items: [appState]),
        ]

        let suggestions = Recommendations.suggestOnly(from: results)
        let categories = Set(suggestions.compactMap { $0.item.category })

        #expect(categories.contains(.bigFiles))
        #expect(categories.contains(.appSupport))
        #expect(!categories.contains(.userCaches))
    }

    @Test func suggestOnlySortsByBytesDescending() {
        let small = ScanItem(url: URL(fileURLWithPath: "/tmp/small.iso"), sizeBytes: 10_000,
                             isDirectory: false, category: .bigFiles)
        let large = ScanItem(url: URL(fileURLWithPath: "/tmp/large.iso"), sizeBytes: 900_000_000,
                             isDirectory: false, category: .bigFiles)
        let medium = ScanItem(url: URL(fileURLWithPath: "/tmp/medium.iso"), sizeBytes: 500_000,
                              isDirectory: false, category: .bigFiles)

        let results = [CategoryResult(category: .bigFiles, items: [small, large, medium])]
        let suggestions = Recommendations.suggestOnly(from: results)

        #expect(suggestions.count == 3)
        #expect(suggestions[0].item.sizeBytes == 900_000_000)
        #expect(suggestions[1].item.sizeBytes == 500_000)
        #expect(suggestions[2].item.sizeBytes == 10_000)
    }

    @Test func suggestOnlyRespectsLimit() {
        let items = (1...30).map { i in
            ScanItem(url: URL(fileURLWithPath: "/tmp/\(i).dat"), sizeBytes: Int64(i * 1000),
                     isDirectory: false, category: .bigFiles)
        }
        let results = [CategoryResult(category: .bigFiles, items: items)]
        let suggestions = Recommendations.suggestOnly(from: results, limit: 10)

        #expect(suggestions.count == 10)
    }
}

@Suite("CategoryScanner improvements")
struct CategoryScannerImprovementsTests {
    func makeFakeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: "mactidy-improvements-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func defaultDevRootsReturnsExistingFoldersUnderHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaults = CategoryScanner.defaultDevRoots
        for url in defaults {
            #expect(url.path.hasPrefix(home.path))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func customDevRootsAreStoredAndUsed() async throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let customRoot = home.appending(path: "MyCustomCode")
        let projDir = customRoot.appending(path: "ProjA")
        let nodeModules = projDir.appending(path: "node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: projDir.appending(path: "package.json"))
        try Data(count: 4096).write(to: nodeModules.appending(path: "index.js"))

        let scanner = CategoryScanner(home: home, devRoots: [customRoot])
        #expect(scanner.devRoots == [customRoot])

        let result = await scanner.scan(.nodeModules)
        #expect(result.items.contains(where: { $0.url.path.contains("ProjA/node_modules") }))
    }

    @Test func precomputeDevRootsCacheRunsAndPopulates() async throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let devDir = home.appending(path: "repos")
        let projDir = devDir.appending(path: "App1")
        let nodeModules = projDir.appending(path: "node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: projDir.appending(path: "package.json"))
        try Data(count: 4096).write(to: nodeModules.appending(path: "app.js"))

        let scanner = CategoryScanner(home: home, devRoots: [devDir])
        let cache = await scanner.precomputeDevRootsCache()

        #expect(cache[.nodeModules] != nil)
        #expect(cache[.nodeModules]?.isEmpty == false)
    }

    @Test func oldInstallersScansDesktopAndDownloads() async throws {
        let fm = FileManager.default
        let home = try makeFakeHome()
        defer { try? fm.removeItem(at: home) }

        let downloads = home.appending(path: "Downloads")
        let desktop = home.appending(path: "Desktop")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)

        let dmg1 = downloads.appending(path: "Tool.dmg")
        let pkg1 = desktop.appending(path: "Package.pkg")
        try Data(count: 4096).write(to: dmg1)
        try Data(count: 4096).write(to: pkg1)

        // Set modification dates 60 days ago so installerMinAgeDays (30) considers them stale.
        let past = Date.now.addingTimeInterval(-60 * 86400)
        try fm.setAttributes([.modificationDate: past], ofItemAtPath: dmg1.path)
        try fm.setAttributes([.modificationDate: past], ofItemAtPath: pkg1.path)

        let scanner = CategoryScanner(home: home, installerMinAgeDays: 30)
        let result = await scanner.scan(.oldInstallers)

        let names = Set(result.items.map(\.url.lastPathComponent))
        #expect(names.contains("Tool.dmg"))
        #expect(names.contains("Package.pkg"))
    }
}

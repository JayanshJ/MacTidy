import Foundation

public struct CategoryResult: Identifiable, Sendable, Codable, Equatable {
    public let category: Category
    public let items: [ScanItem]
    public var id: Category { category }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    public init(category: Category, items: [ScanItem]) {
        self.category = category
        self.items = items
    }
}

/// Read-only scanner for the curated cleanup presets. Where the spec named a
/// single folder (DerivedData, user caches) we surface its *children* so the
/// user gets per-project / per-app granularity instead of all-or-nothing.
public struct CategoryScanner: Sendable {
    public var home: URL
    public var devRoots: [URL]
    public var installerMinAgeDays: Int
    public var screenshotMinAgeDays: Int

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        devRoots: [URL] = CategoryScanner.defaultDevRoots,
        installerMinAgeDays: Int = 30,
        screenshotMinAgeDays: Int = 30
    ) {
        self.home = home
        self.devRoots = devRoots
        self.installerMinAgeDays = installerMinAgeDays
        self.screenshotMinAgeDays = screenshotMinAgeDays
    }

    /// Conventional project folders that exist on this machine.
    public static var defaultDevRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Developer", "Projects", "Code", "src", "dev",
                "repos", "git", "Work", "workspace", "code", "hack"]
            .map { home.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func scanAll(
        progress: (@Sendable (Category) -> Void)? = nil,
        completed: (@Sendable (CategoryResult) -> Void)? = nil
    ) async -> [CategoryResult] {
        // Run the single-pass dev-roots walk ONCE before dispatching
        // categories to parallel tasks. This eliminates the 7+ redundant
        // full-tree walks the old per-category approach did.
        let cache = await devRootsScan()
        return await withTaskGroup(of: CategoryResult.self) { group in
            for category in Category.allCases {
                if Task.isCancelled { break }
                let cacheRef = cache
                group.addTask {
                    if Task.isCancelled { return CategoryResult(category: category, items: []) }
                    progress?(category)
                    return await scanCached(category, devRootsCache: cacheRef)
                }
            }
            var results: [CategoryResult] = []
            for await result in group {
                completed?(result)
                results.append(result)
            }
            return results.sorted { $0.totalBytes > $1.totalBytes }
        }
    }

    /// Pre-computes the dev-roots cache for callers that scan multiple categories
    /// (e.g. scheduled runs or SpaceMonitor) so they share a single walk.
    public func precomputeDevRootsCache() async -> [Category: [ScanItem]] {
        await devRootsScan()
    }

    public func scan(_ category: Category, devRootsCache: [Category: [ScanItem]] = [:]) async -> CategoryResult {
        await scanCached(category, devRootsCache: devRootsCache)
    }

    /// The real scan method. `devRootsCache` carries pre-computed results
    /// from a single-pass dev-roots walk (populated by `scanAll`). When
    /// empty (e.g. when scanning a single category), the build-dir categories
    /// fall back to the old per-category walks.
    private func scanCached(_ category: Category, devRootsCache: [Category: [ScanItem]]) async -> CategoryResult {
        let items: [ScanItem]
        switch category {
        case .xcodeDerivedData:
            items = await children(of: "Library/Developer/Xcode/DerivedData", category)
        case .xcodeDeviceSupport:
            items = await children(of: "Library/Developer/Xcode/iOS DeviceSupport", category)
        case .simulatorCaches:
            items = wholeDir(home.appending(path: "Library/Developer/CoreSimulator/Caches"), category)
        case .simulatorRuntimes:
            items = await children(of: "Library/Developer/CoreSimulator/Images", category)
        case .userCaches:
            items = await children(of: "Library/Caches", category)
        case .homebrewCache:
            items = homebrewCache()
        case .nodeModules:
            items = devRootsCache[.nodeModules] ?? buildDirs(named: "node_modules", siblingMarkers: ["package.json"], category: .nodeModules)
        case .rustTargets:
            items = devRootsCache[.rustTargets] ?? buildDirs(named: "target", siblingMarkers: ["Cargo.toml"], category: .rustTargets)
        case .podDirs:
            items = devRootsCache[.podDirs] ?? buildDirs(named: "Pods", siblingMarkers: ["Podfile"], category: .podDirs)
        case .swiftBuildDirs:
            items = devRootsCache[.swiftBuildDirs] ?? buildDirs(named: ".build", siblingMarkers: ["Package.swift"], category: .swiftBuildDirs)
        case .gradleBuildDirs:
            items = devRootsCache[.gradleBuildDirs] ?? buildDirs(named: "build", siblingMarkers: ["build.gradle", "build.gradle.kts"], category: .gradleBuildDirs)
        case .pythonCaches:
            items = devRootsCache[.pythonCaches] ?? pythonCaches()
        case .jsBuildDirs:
            items = devRootsCache[.jsBuildDirs] ?? jsBuildDirs()
        case .containerCaches:
            items = await containerCaches()
        case .xcodeArchives:
            items = await xcodeArchives()
        case .mailDownloads:
            items = await mailDownloads()
        case .mavenTarget:
            items = devRootsCache[.mavenTarget] ?? buildDirs(named: "target", siblingMarkers: ["pom.xml"], category: .mavenTarget)
        case .phpVendor:
            items = devRootsCache[.phpVendor] ?? buildDirs(named: "vendor", siblingMarkers: ["composer.json"], category: .phpVendor)
        case .flutterDartTool:
            items = devRootsCache[.flutterDartTool] ?? buildDirs(named: ".dart_tool", siblingMarkers: ["pubspec.yaml"], category: .flutterDartTool)
        case .unityLibrary:
            items = devRootsCache[.unityLibrary] ?? unityLibrary()
        case .androidSystemImages:
            items = await androidSystemImages()
        case .staleScreenshots:
            items = staleScreenshots()
        case .oldInstallers:
            items = oldInstallers()
        case .iosBackups:
            items = await iosBackups()
        case .devCaches:
            items = await devCaches()
        case .appSupport:
            items = await appSupportHoarders()
        case .bigFiles:
            items = await bigFiles()
        case .simulatorDevices:
            items = await children(of: "Library/Developer/CoreSimulator/Devices", category)
        case .systemLogs:
            items = await children(of: "Library/Logs", category)
        case .crashReports:
            items = await children(of: "Library/Logs/DiagnosticReports", category)
        case .savedAppState:
            items = await children(of: "Library/Saved Application State", category)
        case .httpStorages:
            items = await children(of: "Library/HTTPStorages", category)
        case .groupContainers:
            items = await children(of: "Library/Group Containers", category)
        }
        return CategoryResult(category: category, items: items)
    }
}

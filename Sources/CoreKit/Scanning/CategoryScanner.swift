import Foundation

public struct CategoryResult: Identifiable, Sendable, Codable, Equatable {
    public let category: Category
    public let items: [ScanItem]
    public var id: Category { category }
    /// Summed once: views sort and total categories on every render.
    public let totalBytes: Int64

    public init(category: Category, items: [ScanItem]) {
        self.category = category
        self.items = items
        self.totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
    }

    private enum CodingKeys: String, CodingKey { case category, items }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(category: try container.decode(Category.self, forKey: .category),
                  items: try container.decode([ScanItem].self, forKey: .items))
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
    /// Paths the user asked never to see again; applied to every result.
    public var ignore: IgnoreList
    /// The apps on this Mac, for telling an app's folder from a leftover.
    /// Nil reads them during the scan.
    public var installedApps: InstalledApps?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        devRoots: [URL] = CategoryScanner.defaultDevRoots,
        installerMinAgeDays: Int = 30,
        screenshotMinAgeDays: Int = 30,
        ignore: IgnoreList = .load(),
        installedApps: InstalledApps? = nil
    ) {
        self.ignore = ignore
        self.installedApps = installedApps
        self.home = home
        self.devRoots = devRoots
        self.installerMinAgeDays = installerMinAgeDays
        self.screenshotMinAgeDays = screenshotMinAgeDays
    }

    static func distinctRoots(_ roots: [URL]) -> [URL] {
        var accepted: [URL] = []
        for root in Set(roots.map { $0.standardizedFileURL }).sorted(by: { $0.path.count < $1.path.count }) {
            guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  !accepted.contains(where: { root.path == $0.path || root.path.hasPrefix($0.path + "/") }) else { continue }
            accepted.append(root)
        }
        return accepted
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
        // The dev-roots categories share one walk (instead of one walk each),
        // run as a single task alongside every other category so the walk
        // doesn't hold up the Library scans.
        await withTaskGroup(of: [CategoryResult].self) { group in
            group.addTask {
                let cache = await devRootsScan()
                var results: [CategoryResult] = []
                for category in Category.allCases where Self.devRootsCategories.contains(category) || category == .bigFiles {
                    if Task.isCancelled { break }
                    progress?(category)
                    results.append(await scanCached(category, devRootsCache: cache))
                }
                return results
            }
            for category in Category.allCases where !Self.devRootsCategories.contains(category) && category != .bigFiles {
                if Task.isCancelled { break }
                group.addTask {
                    if Task.isCancelled { return [] }
                    progress?(category)
                    return [await scanCached(category, devRootsCache: [:])]
                }
            }
            var results: [CategoryResult] = []
            for await batch in group {
                for result in batch {
                    completed?(result)
                    results.append(result)
                }
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
    /// empty, build categories use the same shared classification walk.
    private func scanCached(_ category: Category, devRootsCache: [Category: [ScanItem]]) async -> CategoryResult {
        if Self.devRootsCategories.contains(category), devRootsCache[category] == nil {
            return await scanCached(category, devRootsCache: await devRootsScan())
        }
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
            items = await registryItems(category)
        case .homebrewCache:
            items = homebrewCache()
        case .nodeModules:
            items = devRootsCache[.nodeModules] ?? []
        case .rustTargets:
            items = devRootsCache[.rustTargets] ?? []
        case .podDirs:
            items = devRootsCache[.podDirs] ?? []
        case .swiftBuildDirs:
            items = devRootsCache[.swiftBuildDirs] ?? []
        case .gradleBuildDirs:
            items = devRootsCache[.gradleBuildDirs] ?? []
        case .pythonCaches:
            items = devRootsCache[.pythonCaches] ?? []
        case .jsBuildDirs:
            items = devRootsCache[.jsBuildDirs] ?? []
        case .containerCaches:
            items = await containerCaches()
        case .xcodeArchives:
            items = await xcodeArchives()
        case .mailDownloads:
            items = await mailDownloads()
        case .mavenTarget:
            items = devRootsCache[.mavenTarget] ?? []
        case .phpVendor:
            items = devRootsCache[.phpVendor] ?? []
        case .flutterDartTool:
            items = devRootsCache[.flutterDartTool] ?? []
        case .unityLibrary:
            items = devRootsCache[.unityLibrary] ?? []
        case .androidSystemImages:
            items = await androidSystemImages()
        case .staleScreenshots:
            items = staleScreenshots()
        case .oldInstallers:
            items = oldInstallers()
        case .iosBackups:
            items = await iosBackups()
        case .devCaches, .aiAgents:
            items = await registryItems(category)
        case .appSupport:
            items = await appSupportItems()
        case .bigFiles:
            items = await bigFiles(devRootsCache: devRootsCache)
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
            // A container holding something handled elsewhere is listed there.
            items = await groupContainerItems()
                .filter { !HandledElsewhere.claimsGroupContainer($0.url.lastPathComponent) }
        }
        return CategoryResult(category: category, items: items.filter { !ignore.contains($0.url) })
    }
}

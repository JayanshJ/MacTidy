import Foundation

/// A curated cleanup category. Categories marked `isPreselectable == false`
/// are suggest-only: build artifacts of possibly-active projects that the
/// user must opt into item by item.
public enum Category: String, CaseIterable, Codable, Sendable, Identifiable {
    case xcodeDerivedData
    case xcodeDeviceSupport
    case simulatorCaches
    case simulatorRuntimes
    case userCaches
    case homebrewCache
    case nodeModules
    case rustTargets
    case podDirs
    case swiftBuildDirs
    case gradleBuildDirs
    case pythonCaches
    case jsBuildDirs
    case containerCaches
    case xcodeArchives
    case mailDownloads
    case mavenTarget
    case phpVendor
    case flutterDartTool
    case unityLibrary
    case androidSystemImages
    case staleScreenshots
    case oldInstallers
    case iosBackups
    case devCaches
    case appSupport
    case bigFiles

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .xcodeDerivedData: "Xcode DerivedData"
        case .xcodeDeviceSupport: "Xcode iOS DeviceSupport"
        case .simulatorCaches: "Simulator caches"
        case .simulatorRuntimes: "Simulator runtimes"
        case .userCaches: "User caches"
        case .homebrewCache: "Homebrew cache"
        case .nodeModules: "node_modules"
        case .rustTargets: "Rust target/"
        case .podDirs: "CocoaPods Pods/"
        case .swiftBuildDirs: "SwiftPM .build/"
        case .gradleBuildDirs: "Gradle build/"
        case .pythonCaches: "Python caches"
        case .jsBuildDirs: "JS build dirs"
        case .containerCaches: "Sandboxed app caches"
        case .xcodeArchives: "Xcode Archives"
        case .mailDownloads: "Mail Downloads"
        case .mavenTarget: "Maven target/"
        case .phpVendor: "PHP vendor/"
        case .flutterDartTool: "Flutter .dart_tool/"
        case .unityLibrary: "Unity Library/"
        case .androidSystemImages: "Android system images"
        case .staleScreenshots: "Stale screenshots"
        case .oldInstallers: "Old installers"
        case .iosBackups: "iOS device backups"
        case .devCaches: "Developer tool caches"
        case .appSupport: "Application Support hoarders"
        case .bigFiles: "Large files"
        }
    }

    public var explanation: String {
        switch self {
        case .xcodeDerivedData:
            "Per-project build products and indexes. Xcode regenerates these on the next build."
        case .xcodeDeviceSupport:
            "Debug symbols for iOS versions you've plugged in. Recreated when a device is next connected."
        case .simulatorCaches:
            "CoreSimulator caches. Safe to clear; simulators recreate them."
        case .simulatorRuntimes:
            "Downloaded iOS/watchOS/tvOS simulator runtimes. Xcode re-downloads a runtime when you next try to run it. Suggest-only: re-downloading is large and slow."
        case .userCaches:
            "Per-app caches in ~/Library/Caches. Apps rebuild these, but some may launch slower once."
        case .homebrewCache:
            "Downloaded bottles and source tarballs. brew re-downloads on demand."
        case .nodeModules:
            "Installed npm dependencies. Suggest-only: check the project is inactive, restore with npm install."
        case .rustTargets:
            "Cargo build artifacts (dirs named target with a sibling Cargo.toml). Restore with cargo build."
        case .podDirs:
            "CocoaPods dependency dirs (a Pods folder with a sibling Podfile). Regenerable — restore with `pod install`."
        case .swiftBuildDirs:
            "SwiftPM build artifacts (a .build folder with a sibling Package.swift). Regenerable — restore with `swift build`."
        case .gradleBuildDirs:
            "Gradle project build output (a build folder with a sibling build.gradle[.kts]). Regenerable — restore with `./gradlew assemble`."
        case .pythonCaches:
            "Python bytecode caches (__pycache__) and virtualenvs (.venv with a sibling pyproject.toml/requirements.txt). Suggest-only: virtualenvs are regenerable but often worth keeping — check before trashing."
        case .jsBuildDirs:
            "JS framework build output (.next, .nuxt, .svelte-kit, .turbo, .output dirs with a sibling package.json). Regenerable — restore with the framework's build command."
        case .containerCaches:
            "Per-app caches inside sandboxed app containers (~/Library/Containers/*/Data/Library/Caches). Apps rebuild these; some may launch slower once."
        case .xcodeArchives:
            "Xcode archive bundles in ~/Library/Developer/Xcode/Archives. Suggest-only: these hold symbols for past uploads — keep them until you're sure you won't need to symbolicate an old crash."
        case .mailDownloads:
            "Mail attachment cache (~/Library/Containers/com.apple.Mail/…/Mail Downloads). Mail re-downloads from the server when you open the message."
        case .mavenTarget:
            "Maven project build output (a target folder with a sibling pom.xml). Regenerable — restore with `mvn package`."
        case .phpVendor:
            "Composer dependencies (a vendor folder with a sibling composer.json). Regenerable — restore with `composer install`."
        case .flutterDartTool:
            "Flutter/Dart build cache (a .dart_tool folder with a sibling pubspec.yaml). Regenerable — restore with `flutter pub get`."
        case .unityLibrary:
            "Unity's imported-asset cache (a Library folder under a Unity project, gated on a sibling ProjectSettings dir). Suggest-only: Unity re-imports every asset on rebuild, which can take a long time."
        case .androidSystemImages:
            "Downloaded Android SDK system images (~​/Library/Android/sdk/system-images). Suggest-only: each is needed by a specific AVD; re-download is large and slow."
        case .staleScreenshots:
            "Screenshot files on your Desktop older than 30 days. Suggest-only: these are your files, not regenerable — review before trashing."
        case .oldInstallers:
            "Disk images and installer packages in ~/Downloads you probably already installed."
        case .iosBackups:
            "Local iPhone/iPad backups from Finder syncing. Suggest-only: make sure the device is backed up elsewhere (or no longer yours) first."
        case .devCaches:
            "npm, pnpm, Cargo, Gradle, Go, Maven, Yarn, and Terraform caches outside ~/Library/Caches. All re-download on demand."
        case .appSupport:
            "Per-app data folders in ~/Library/Application Support, largest first. Suggest-only: these hold real app state (config, databases, messages); trashing resets the app, so check what each is before deleting."
        case .bigFiles:
            "Individual files over 100 MB anywhere under your home. Suggest-only: large files aren't necessarily junk — review each before trashing."
        }
    }

    /// Whether it's safe to preselect the whole category for bulk cleanup.
    /// Build dirs of possibly-active projects, device backups, app state, and
    /// arbitrary large files are never preselected.
    public var isPreselectable: Bool {
        switch self {
        case .nodeModules, .rustTargets, .iosBackups, .simulatorRuntimes,
             .appSupport, .bigFiles, .pythonCaches, .xcodeArchives,
             .unityLibrary, .androidSystemImages, .staleScreenshots:
            false
        default:
            true
        }
    }
}

/// One scanned filesystem entry with its on-disk allocated size.
public struct ScanItem: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let url: URL
    /// Total allocated size in bytes (for directories: sum of children).
    public let sizeBytes: Int64
    public let isDirectory: Bool
    public let category: Category?
    /// Extra context shown in the UI, e.g. the parent project of a node_modules dir.
    public let detail: String?
    public let lastModified: Date?

    public init(
        url: URL,
        sizeBytes: Int64,
        isDirectory: Bool,
        category: Category? = nil,
        detail: String? = nil,
        lastModified: Date? = nil
    ) {
        self.id = UUID()
        self.url = url
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.category = category
        self.detail = detail
        self.lastModified = lastModified
    }

    /// Codable with a stable key list so persisted scans survive enum reorders.
    enum CodingKeys: String, CodingKey {
        case id, url, sizeBytes, isDirectory, category, detail, lastModified
    }
}

public extension Int64 {
    /// Finder-style byte formatting ("1.2 GB").
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

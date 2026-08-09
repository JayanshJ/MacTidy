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
             .appSupport, .bigFiles:
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

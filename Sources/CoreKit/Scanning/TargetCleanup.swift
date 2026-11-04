import Foundation

public enum CleanupCost: Int, Sendable, Comparable {
    case rebuilds, downloads, reinstall, personalData
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var explanation: String {
        switch self {
        case .rebuilds: "Rebuilds when needed; the next launch or build may be slower."
        case .downloads: "Needs a download again before use."
        case .reinstall: "Needs rebuilding or reinstalling before use. Check that you can restore it."
        case .personalData: "May contain personal data or settings. Review before choosing."
        }
    }
}

/// A cost-ordered proposal, never an execution. Review items remain unchecked.
public struct TargetCleanup: Sendable {
    public let items: [ScanItem]
    public let targetBytes: Int64
    public var proposedBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    public var initialSelection: Set<UUID> { Set(items.filter(\.isPreselectable).map(\.id)) }

    public static func cost(_ item: ScanItem) -> CleanupCost {
        if item.isPreselectable { return .rebuilds }
        if item.category == .simulatorRuntimes || item.category == .androidSystemImages { return .downloads }
        let insight = item.category == .appSupport ? AppSupportRules.insight(for: item) : nil
        let source = CleanSource.source(for: item)
        let label = [item.detail, source?.label, insight?.explanation].compactMap { $0 }.joined(separator: " ").lowercased()
        if label.contains("re-download") || label.contains("re-pull") || label.contains("downloaded again") {
            return .downloads
        }
        if item.finding == BuildOutput.finding || item.finding == BuildOutput.xcodeFinding
            || [.nodeModules, .rustTargets, .podDirs, .swiftBuildDirs, .gradleBuildDirs,
                .jsBuildDirs, .mavenTarget, .phpVendor, .flutterDartTool, .unityLibrary].contains(item.category)
            || label.contains("reinstall") {
            return .reinstall
        }
        return .personalData
    }

    public init(results: [CategoryResult], targetBytes: Int64, policy: SafePathPolicy = SafePathPolicy()) {
        self.targetBytes = max(0, targetBytes)
        let candidates = results.flatMap(\.items).filter {
            guard $0.category != nil, $0.sizeBytes > 0 else { return false }
            if case .success = policy.classify($0.url) { return true }
            return false
        }.sorted {
            if Self.cost($0) != Self.cost($1) { return Self.cost($0) < Self.cost($1) }
            if $0.lastModified != $1.lastModified {
                return ($0.lastModified ?? .distantFuture) < ($1.lastModified ?? .distantFuture)
            }
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.url.path < $1.url.path
        }
        var chosen: [ScanItem] = []
        var bytes: Int64 = 0
        for item in candidates where bytes < self.targetBytes {
            let path = item.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !chosen.contains(where: {
                let other = $0.url.resolvingSymlinksInPath().standardizedFileURL.path
                return path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/")
            }) else { continue }
            chosen.append(item)
            bytes += item.sizeBytes
        }
        items = chosen
    }

    public static func bytes(fromGB text: String) -> Int64? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite,
              value >= 0.001, value <= 1_000_000 else { return nil }
        return Int64(value * 1_000_000_000)
    }
}

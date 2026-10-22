import Foundation

/// Paths the user never wants suggested again. An entry hides itself and
/// everything inside it. Stored in UserDefaults so every scanner — full
/// scans, scheduled runs, the menu bar quick check — honors it.
public struct IgnoreList: Sendable, Codable, Equatable {
    public private(set) var paths: [String]

    public init(paths: [String] = []) {
        self.paths = paths.map(Self.normalize)
    }

    public var isEmpty: Bool { paths.isEmpty }

    public func contains(_ url: URL) -> Bool {
        let path = Self.normalize(url.path)
        return paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public mutating func add(_ url: URL) {
        let path = Self.normalize(url.path)
        guard !paths.contains(path) else { return }
        paths.append(path)
        paths.sort()
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == Self.normalize(path) }
    }

    public func filter(_ results: [CategoryResult]) -> [CategoryResult] {
        guard !isEmpty else { return results }
        return results.map { CategoryResult(category: $0.category, items: $0.items.filter { !contains($0.url) }) }
    }

    /// Symlink-resolved, so an entry matches however the path was reached.
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: Persistence

    public static let defaultsKey = "MacTidy.ignoredPaths"

    public static func load(from defaults: UserDefaults = .standard) -> IgnoreList {
        IgnoreList(paths: defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(paths, forKey: Self.defaultsKey)
    }
}

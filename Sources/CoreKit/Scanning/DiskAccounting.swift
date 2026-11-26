import Foundation

/// Read-only estimates with disjoint filesystem roots. Unreadable files,
/// snapshots and APFS sharing stay explicit rather than being called junk.
public struct DiskAccounting: Sendable {
    public struct Part: Identifiable, Sendable {
        /// Where a row can lead. macOS volumes and memory files lead nowhere:
        /// there is nothing there for the user to act on.
        public enum Destination: Sendable, Equatable {
            /// Open this folder in Disk Map.
            case folder(URL)
            /// The Trash (MacTidy's Recently Trashed page).
            case trash
        }
        public let name: String
        public let bytes: Int64
        public let destination: Destination?
        public var id: String { name }
        public init(name: String, bytes: Int64, destination: Destination? = nil) {
            self.name = name; self.bytes = bytes; self.destination = destination
        }
    }
    public let parts: [Part]
    public let pressure: DiskPressure?
    public let physicalFree: Int64?
    public let snapshotCount: Int?
    public init(parts: [Part], pressure: DiskPressure?, physicalFree: Int64?, snapshotCount: Int?) {
        self.parts = parts; self.pressure = pressure; self.physicalFree = physicalFree
        self.snapshotCount = snapshotCount
    }
    public var measuredBytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }
    public var unaccountedBytes: Int64? {
        guard let pressure, let physicalFree else { return nil }
        return max(0, pressure.totalBytes - physicalFree - measuredBytes)
    }
    public var potentiallyPurgeable: Int64? {
        guard let pressure, let physicalFree else { return nil }
        return max(0, pressure.freeBytes - physicalFree)
    }

    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let fm = FileManager.default
        // Home children partition home without measuring its Library twice.
        let children = (try? fm.contentsOfDirectory(at: home,
            includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        let localChildren = children.filter {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
        let outside: [(String, URL)] = [
            ("Applications", URL(fileURLWithPath: "/Applications")),
            ("Shared Library", URL(fileURLWithPath: "/Library")),
            ("System memory files (keep)", URL(fileURLWithPath: "/private/var/vm")),
        ]
        let roots = localChildren + outside.map(\.1)
        var sizes = BulkWalker.allocatedSizes(of: roots.map(\.path), materializingDataless: false)
        for (index, root) in roots.enumerated() {
            if let values = try? root.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
               values.isRegularFile == true { sizes[index] = Int64(values.totalFileAllocatedSize ?? 0) }
        }
        var parts = Self.homeParts(home: home, children: Array(zip(localChildren, sizes)))
        for (index, root) in outside.enumerated() {
            // Memory files belong to macOS: shown, never linked.
            let link: Part.Destination? = root.1.path == "/private/var/vm" ? nil : .folder(root.1)
            parts.append(Part(name: root.0, bytes: sizes[localChildren.count + index], destination: link))
        }
        if let output = Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]), output.succeeded,
           let data = output.stdout.data(using: .utf8), let volumes = Self.systemVolumes(in: data) {
            parts.append(contentsOf: volumes)
        }
        let snapshotOutput = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        let count = snapshotOutput.flatMap { $0.succeeded ? Self.snapshotCount(in: $0.stdout) : nil }
        return Self(parts: parts, pressure: DiskPressure.current(), physicalFree: TrashEmptying.freeBytes(), snapshotCount: count)
    }

    /// Splits home's top-level children into disjoint parts: Library, Trash,
    /// and everything else. Each byte lands in exactly one part.
    public static func homeParts(home: URL, children: [(URL, Int64)]) -> [Part] {
        var library: Int64 = 0, trash: Int64 = 0, rest: Int64 = 0
        for (child, bytes) in children {
            switch child.lastPathComponent {
            case "Library": library += bytes
            case ".Trash": trash += bytes
            default: rest += bytes
            }
        }
        var parts = [Part(name: "Home Library", bytes: library, destination: .folder(home.appending(path: "Library"))),
                     Part(name: "Other home files", bytes: rest, destination: .folder(home))]
        if trash > 0 { parts.append(Part(name: "Trash", bytes: trash, destination: .trash)) }
        return parts
    }

    public static func systemVolumes(in data: Data) -> [Part]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]],
              let boot = containers.first(where: { container in
                  (container["Volumes"] as? [[String: Any]])?.contains {
                      ($0["MountPoint"] as? String) == "/System/Volumes/Data"
                  } == true
              }), let volumes = boot["Volumes"] as? [[String: Any]] else { return nil }
        return volumes.compactMap { volume in
            let roles = volume["Roles"] as? [String] ?? []
            guard roles.contains(where: { ["System", "Preboot", "Recovery"].contains($0) }),
                  let bytes = volume["CapacityInUse"] as? Int64 else { return nil }
            return Part(name: "macOS \(roles.joined(separator: ", ")) volume", bytes: bytes)
        }
    }

    public static func snapshotCount(in output: String) -> Int {
        output.split(separator: "\n").filter { $0.hasPrefix("com.apple.TimeMachine.") }.count
    }
}

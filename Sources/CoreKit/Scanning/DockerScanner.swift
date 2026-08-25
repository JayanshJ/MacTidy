import Foundation

/// Structured Docker state for the Docker cleanup tab. Distinct from
/// `DockerInfo`, which only exposes the raw `docker system df` table — this
/// parses images/containers into models the UI can group and act on.
public struct DockerImage: Identifiable, Sendable, Hashable {
    public let id: String
    public let repository: String
    public let tag: String
    public let sizeBytes: Int64
    public let createdSince: String
    public let composeProject: String?
    public var dangling: Bool { repository == "<none>" && tag == "<none>" }

    public init(id: String, repository: String, tag: String,
                sizeBytes: Int64, createdSince: String, composeProject: String?) {
        self.id = id
        self.repository = repository
        self.tag = tag
        self.sizeBytes = sizeBytes
        self.createdSince = createdSince
        self.composeProject = composeProject
    }
}

public struct DockerContainer: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let image: String
    public let running: Bool

    public init(id: String, name: String, image: String, running: Bool) {
        self.id = id
        self.name = name
        self.image = image
        self.running = running
    }
}

public struct DockerComposeProject: Identifiable, Sendable, Hashable {
    public let name: String
    public let images: [DockerImage]
    public let running: Bool
    public var id: String { name }
    public var totalBytes: Int64 { images.reduce(0) { $0 + $1.sizeBytes } }

    public init(name: String, images: [DockerImage], running: Bool) {
        self.name = name
        self.images = images
        self.running = running
    }
}

public struct DockerState: Sendable {
    public let images: [DockerImage]
    public let containers: [DockerContainer]
    public let projects: [DockerComposeProject]

    public init(images: [DockerImage], containers: [DockerContainer]) {
        self.images = images
        self.containers = containers
        // Group images by compose project label, ignoring nil/empty.
        let grouped = Dictionary(grouping: images.filter { !($0.composeProject?.isEmpty ?? true) },
                                 by: { $0.composeProject! })
        self.projects = grouped.map { name, imgs in
            // A project is "running" (instantiated) if any container's image
            // matches one of the project's images by repo:tag or image-id
            // substring. The container itself need not be Up — an Exited
            // container still indicates the project has been brought up.
            let running = containers.contains { c in
                imgs.contains { img in
                    c.image == "\(img.repository):\(img.tag)" || c.image.contains(img.id)
                }
            }
            return DockerComposeProject(name: name, images: imgs, running: running)
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    public var standaloneImages: [DockerImage] {
        images.filter { $0.composeProject?.isEmpty ?? true }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }
}

public enum DockerScanner {
    public enum Availability: Sendable { case available, notInstalled, notRunning }

    /// Looks up the docker binary in standard locations only (no $PATH).
    public static func availability() -> Availability {
        guard let docker = Shell.find("docker") else { return .notInstalled }
        guard let out = Shell.run(docker, ["info", "--format", "{{.ServerVersion}}"]),
              out.succeeded else { return .notRunning }
        return .available
    }

    /// Full structured scan. Returns nil when docker is unavailable.
    public static func scan() -> DockerState? {
        guard let docker = Shell.find("docker") else { return nil }
        guard let imagesRaw = Shell.run(docker, ["images", "--no-trunc", "--format",
                "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}"]),
              imagesRaw.succeeded else { return nil }
        let containersRaw = Shell.run(docker, ["ps", "-a", "--format",
                "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"])
        let images = parseImages(imagesRaw.stdout) { id in
            guard let inspect = Shell.run(docker, ["image", "inspect", id, "--format",
                    "{{ index .Config.Labels \"com.docker.compose.project\" }}"]),
                  inspect.succeeded else { return "" }
            return inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let containers = parseContainers(containersRaw?.stdout ?? "")
        return DockerState(images: images, containers: containers)
    }

    /// Raw `docker system df` table for the secondary detail view. Delegates
    /// to the existing DockerInfo usage() but returns the string directly.
    public static func systemDFTable() -> String? { DockerInfo.usage()?.table }

    // MARK: - Parsers (pure, testable without docker)

    /// Parses `docker images --format` tab-separated rows. `inspect` returns the
    /// compose-project label for a given image ID (empty string when none).
    public static func parseImages(_ raw: String, inspect: (String) -> String) -> [DockerImage] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 5 else { return nil }
            let id = cols[2]
            // docker prints IDs as "sha256:..."; strip the prefix for display but keep full.
            let project = inspect(id)
            return DockerImage(
                id: id,
                repository: cols[0],
                tag: cols[1],
                sizeBytes: parseSize(cols[3]),
                createdSince: cols[4],
                composeProject: project.isEmpty ? nil : project
            )
        }
    }

    /// Parses `docker ps -a --format` tab-separated rows. Status starting
    /// with "Up" → running.
    public static func parseContainers(_ raw: String) -> [DockerContainer] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 4 else { return nil }
            return DockerContainer(
                id: cols[0],
                name: cols[1],
                image: cols[2],
                running: cols[3].hasPrefix("Up")
            )
        }
    }

    /// Parses a human docker size ("100MB", "1.2GB", "5.43kB") to bytes.
    static func parseSize(_ s: String) -> Int64 {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract numeric prefix and unit suffix.
        var numStr = ""
        var unit = ""
        for ch in trimmed {
            if ch.isNumber || ch == "." { numStr.append(ch) }
            else { unit.append(ch) }
        }
        guard let value = Double(numStr) else { return 0 }
        let key = unit.uppercased()
        let mult: Double
        switch key {
        case "B", "": mult = 1
        case "KB", "K": mult = 1_000
        case "MB", "M": mult = 1_000_000
        case "GB", "G": mult = 1_000_000_000
        case "TB", "T": mult = 1_000_000_000_000
        default: mult = 1
        }
        return Int64(value * mult)
    }
}
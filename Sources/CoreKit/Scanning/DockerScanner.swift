import Foundation

/// Structured Docker state for the Docker cleanup tab. Parses images/
/// containers into models the UI can group and act on. Also exposes the raw
/// `docker system df` table via `systemDFTable()`.
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

/// A heuristic attribution for an image without a compose project label —
/// i.e. a plain `docker run` image that's really part of some project's
/// workflow but doesn't carry the label. Derived from the container's
/// working directory and bind mounts, so it only resolves when a container
/// references the image. Always a *guess*: the UI labels it "likely".
public struct DockerImageAttribution: Sendable, Equatable {
    /// Best-guess project name (a directory name or container/image name),
    /// or nil when nothing could be inferred.
    public let projectGuess: String?
    /// True when a running container references the image — the strongest
    /// "do not prune" signal, independent of the project guess.
    public let inUse: Bool

    public init(projectGuess: String?, inUse: Bool) {
        self.projectGuess = projectGuess
        self.inUse = inUse
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

public struct DockerVolume: Identifiable, Sendable, Hashable {
    public let name: String
    public let links: Int
    public let sizeBytes: Int64
    public var id: String { name }
    public var inUse: Bool { links > 0 }

    public init(name: String, links: Int, sizeBytes: Int64) {
        self.name = name
        self.links = links
        self.sizeBytes = sizeBytes
    }
}

public struct DockerContext: Identifiable, Sendable, Hashable {
    public let name: String
    public let isCurrent: Bool
    public let endpoint: String
    public var id: String { name }

    public init(name: String, isCurrent: Bool, endpoint: String) {
        self.name = name
        self.isCurrent = isCurrent
        self.endpoint = endpoint
    }
}

public struct DockerState: Sendable {
    public let images: [DockerImage]
    public let containers: [DockerContainer]
    public let projects: [DockerComposeProject]
    public let volumes: [DockerVolume]
    public let contexts: [DockerContext]
    /// Heuristic attributions for standalone (non-compose) images, keyed by
    /// image id. Images with no container and no resolvable project get no
    /// entry (they're truly "orphaned"); the UI treats a missing key as
    /// orphaned. See `DockerScanner.parseAttributions`.
    public let attributions: [String: DockerImageAttribution]

    public init(images: [DockerImage], containers: [DockerContainer],
                volumes: [DockerVolume] = [], contexts: [DockerContext] = []) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
        self.contexts = contexts
        // Group images by compose project label, ignoring nil/empty.
        let grouped = Dictionary(grouping: images.filter { !($0.composeProject?.isEmpty ?? true) },
                                 by: { $0.composeProject! })
        self.projects = grouped.map { name, imgs in
            // A project is "running" when a container in "Up" status references
            // one of the project's images by repo:tag or image-id substring.
            // Stopped/Exited containers do not count — a project with only
            // stopped containers is not running.
            let running = containers.contains { c in
                c.running && imgs.contains { img in
                    c.image == "\(img.repository):\(img.tag)" || c.image.contains(img.id)
                }
            }
            return DockerComposeProject(name: name, images: imgs, running: running)
        }
        .sorted { $0.totalBytes > $1.totalBytes }
        // Standalone-image attributions are derived in `scan()` (they need
        // container inspect data) and injected via the dedicated initializer
        // below; the plain initializer leaves them empty.
        self.attributions = [:]
    }

    /// Designated initializer that carries pre-computed standalone-image
    /// attributions (from `DockerScanner.parseAttributions`). Kept internal
    /// to the scan path; the plain initializer above is for tests/empty state.
    public init(images: [DockerImage], containers: [DockerContainer],
                attributions: [String: DockerImageAttribution],
                volumes: [DockerVolume] = [], contexts: [DockerContext] = []) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
        self.contexts = contexts
        let grouped = Dictionary(grouping: images.filter { !($0.composeProject?.isEmpty ?? true) },
                                 by: { $0.composeProject! })
        self.projects = grouped.map { name, imgs in
            let running = containers.contains { c in
                c.running && imgs.contains { img in
                    c.image == "\(img.repository):\(img.tag)" || c.image.contains(img.id)
                }
            }
            return DockerComposeProject(name: name, images: imgs, running: running)
        }
        .sorted { $0.totalBytes > $1.totalBytes }
        self.attributions = attributions
    }

    public var standaloneImages: [DockerImage] {
        images.filter { $0.composeProject?.isEmpty ?? true }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Convenience: the attribution for a standalone image, or nil when the
    /// image has no resolvable project and no referencing container — i.e.
    /// it's orphaned.
    public func attribution(for image: DockerImage) -> DockerImageAttribution? {
        attributions[image.id]
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

        let rawImages = parseImages(imagesRaw.stdout) { _ in "" }
        let imageIDs = Array(Set(rawImages.map(\.id)))
        var projectLabels: [String: String] = [:]
        if !imageIDs.isEmpty,
           let inspectOut = Shell.run(docker, ["image", "inspect", "--format",
                "{{.ID}}\t{{ index .Config.Labels \"com.docker.compose.project\" }}"] + imageIDs),
           inspectOut.succeeded {
            projectLabels = parseBatchedInspect(inspectOut.stdout)
        }
        let images = parseImages(imagesRaw.stdout) { id in
            projectLabels[id] ?? ""
        }

        let containers = parseContainers(containersRaw?.stdout ?? "")
        let containerIDs = Array(Set(containers.map(\.id)))
        var containerInspects: [String: String] = [:]
        if !containerIDs.isEmpty,
           let inspectOut = Shell.run(docker, ["inspect", "--type", "container", "--format",
                "{{.ID}}\t{{.Config.WorkingDir}}|{{range .Mounts}}{{if eq .Type \"bind\"}}{{.Source}},{{end}}{{end}}"] + containerIDs),
           inspectOut.succeeded {
            containerInspects = parseBatchedInspect(inspectOut.stdout)
        }
        let attributions = parseAttributions(images: images, containers: containers) { shortID in
            if let exact = containerInspects[shortID] { return exact }
            return containerInspects.first { $0.key.hasPrefix(shortID) }?.value ?? ""
        }

        let dfVerbose = Shell.run(docker, ["system", "df", "-v"])
        let volumes = (dfVerbose?.succeeded == true)
            ? parseVolumesFromSystemDF(dfVerbose?.stdout ?? "")
            : []
        let contextOut = Shell.run(docker, ["context", "ls", "--format",
                "{{.Name}}\t{{.Current}}\t{{.DockerEndpoint}}"])
        let contexts = (contextOut?.succeeded == true)
            ? parseContexts(contextOut?.stdout ?? "")
            : []

        return DockerState(
            images: images,
            containers: containers,
            attributions: attributions,
            volumes: volumes,
            contexts: contexts
        )
    }

    public static func switchContext(_ name: String) -> Shell.Output? {
        guard let docker = Shell.find("docker") else { return nil }
        return Shell.run(docker, ["context", "use", name])
    }

    public static func parseBatchedInspect(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let id = String(line[..<tab]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { out[id] = value }
        }
        return out
    }

    public static func parseVolumesFromSystemDF(_ raw: String) -> [DockerVolume] {
        var inVolumes = false
        var seenHeader = false
        var volumes: [DockerVolume] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Local Volumes space usage:") {
                inVolumes = true
                seenHeader = false
                continue
            }
            guard inVolumes else { continue }
            if line.isEmpty {
                if seenHeader { break }
                continue
            }
            if line.hasPrefix("VOLUME NAME") {
                seenHeader = true
                continue
            }
            if line.hasPrefix("Build cache usage:") { break }
            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard cols.count >= 3, let links = Int(cols[1]) else { continue }
            volumes.append(DockerVolume(
                name: cols[0],
                links: links,
                sizeBytes: parseSize(cols[2])
            ))
        }
        return volumes.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    public static func parseContexts(_ raw: String) -> [DockerContext] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3 else { return nil }
            return DockerContext(
                name: cols[0],
                isCurrent: cols[1].lowercased() == "true",
                endpoint: cols[2]
            )
        }
    }

    /// Raw `docker system df` table for the secondary detail view. Returns
    /// the stdout verbatim, or nil when Docker isn't installed/running.
    public static func systemDFTable() -> String? {
        guard let docker = Shell.find("docker"),
              let output = Shell.run(docker, ["system", "df"]),
              output.succeeded,
              !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return output.stdout
    }

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

    /// Builds heuristic attributions for standalone (non-compose) images.
    /// `containerInspect` returns, for a container id, a single string of the
    /// form `workingDir|bindSrc1,bindSrc2,` — matching the `--format` template
    /// used in `scan()` (empty string when inspect fails).
    ///
    /// An image gets an attribution entry only when at least one container
    /// references it (by repo:tag or image-id substring). `inUse` is true
    /// when any referencing container is running. `projectGuess` is inferred
    /// from the working dir or a bind mount's source path — the deepest
    /// directory name that isn't a root/home/tmp trivial — falling back to
    /// the container name and finally the image repo. Images with no
    /// referencing container get no entry (truly orphaned).
    public static func parseAttributions(
        images: [DockerImage],
        containers: [DockerContainer],
        containerInspect: (String) -> String
    ) -> [String: DockerImageAttribution] {
        let standalone = images.filter { $0.composeProject?.isEmpty ?? true }
        var out: [String: DockerImageAttribution] = [:]
        for img in standalone {
            // Containers referencing this image (repo:tag or id substring).
            let refs = containers.filter { c in
                c.image == "\(img.repository):\(img.tag)" || c.image.contains(img.id)
            }
            guard !refs.isEmpty else { continue }
            let inUse = refs.contains { $0.running }
            // First referencing container whose inspect resolves to a guess.
            var guess: String? = nil
            for ref in refs {
                if let g = inferProject(from: containerInspect(ref.id), container: ref, image: img) {
                    guess = g
                    break
                }
            }
            out[img.id] = DockerImageAttribution(projectGuess: guess, inUse: inUse)
        }
        return out
    }

    /// Picks a project name from a container's `workingDir|bindSources` string.
    /// Prefers a bind mount source (project dirs are usually bind-mounted in),
    /// then the working dir, then falls back to the container name and image
    /// repo. Trivial paths (`/`, `$HOME`, `/tmp`, `/app`, `/data`, …) are
    /// rejected so we don't surface "app" or "tmp" as a project.
    private static func inferProject(from inspect: String, container: DockerContainer, image: DockerImage) -> String? {
        let parts = inspect.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let workingDir = parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let bindSources = parts.count > 1
            ? parts[1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            : []
        // Prefer the deepest non-trivial directory name from any bind mount,
        // then the working dir. Bind mounts pointing at a project root are the
        // strongest signal that the image belongs to that project.
        for src in bindSources {
            if let name = meaningfulDirName(src) { return name }
        }
        if let name = meaningfulDirName(workingDir) { return name }
        // Fall back to the container name (strip a trailing `-1`/`_1` replica
        // suffix that compose-style naming leaves even for plain `docker run`).
        let trimmedName = container.name.replacingOccurrences(of: #"[-_]\d+$"#, with: "", options: .regularExpression)
        if !trimmedName.isEmpty { return trimmedName }
        // Last resort: the image repo, when it's not "<none>".
        if !image.dangling && !image.repository.isEmpty { return image.repository }
        return nil
    }

    /// The last path component of `path` when it's a meaningful project-ish
    /// directory — rejecting trivial roots that would produce useless guesses
    /// like "app", "tmp", or the home dir name.
    private static func meaningfulDirName(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let last = (trimmed as NSString).lastPathComponent
        guard !last.isEmpty else { return nil }
        let trivial: Set<String> = [
            "/", "app", "apps", "src", "code", "workspace", "workspaces",
            "data", "tmp", "temp", "var", "opt", "home", "root", "Users",
            "mnt", "host", "project", "projects", "repo",
        ]
        if trivial.contains(last) { return nil }
        // Reject a bare home dir (`/Users/jayansh`) — not a project name.
        if trimmed.hasPrefix("/Users/") && trimmed.split(separator: "/").count == 3 { return nil }
        return last
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
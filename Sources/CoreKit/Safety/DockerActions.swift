import Foundation

/// Removes one Docker image by ID. `docker rmi -f` forces removal even when the
/// image has tagged children. Irreversible — no Trash.
public struct DockerImageRemoveAction: ShellAction {
    public let id = UUID()
    public let image: DockerImage
    public var displayName: String {
        image.dangling ? "dangling image \(image.id)" : "\(image.repository):\(image.tag)"
    }
    public var commandSummary: String { "docker rmi -f \(image.id)" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { image.sizeBytes }

    public init(image: DockerImage) { self.image = image }

    public func run() -> Shell.Output? {
        guard let docker = Shell.find("docker") else { return nil }
        return Shell.run(docker, ["rmi", "-f", image.id])
    }
}

/// Tears down a whole Compose project: stops its containers and removes its
/// images (`--rmi all`). Volumes are preserved by default; pass
/// `removeVolumes: true` to also remove named volumes (destructive for DBs).
public struct DockerComposeDownAction: ShellAction {
    public let id = UUID()
    public let project: DockerComposeProject
    public let removeVolumes: Bool
    public var displayName: String { "Compose project \(project.name)" }
    public var commandSummary: String {
        var cmd = "docker compose -p \(project.name) down --rmi all"
        if removeVolumes { cmd += " --volumes" }
        return cmd
    }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { project.totalBytes }

    public init(project: DockerComposeProject, removeVolumes: Bool = false) {
        self.project = project
        self.removeVolumes = removeVolumes
    }

    public func run() -> Shell.Output? {
        guard let docker = Shell.find("docker") else { return nil }
        var args = ["compose", "-p", project.name, "down", "--rmi", "all"]
        if removeVolumes { args.append("--volumes") }
        return Shell.run(docker, args)
    }
}

/// Removes a container by ID. For a running container, `docker rm -f` stops
/// it first then removes it; for a stopped container, plain `docker rm`
/// suffices. The literal command is shown in the confirmation sheet so the
/// force-stop is never hidden. Reclaims ~0 disk (containers are tiny layers).
public struct DockerContainerRemoveAction: ShellAction {
    public let id = UUID()
    public let container: DockerContainer
    public var displayName: String {
        "\(container.running ? "running" : "stopped") container \(container.name)"
    }
    public var commandSummary: String {
        container.running ? "docker rm -f \(container.id)" : "docker rm \(container.id)"
    }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init(container: DockerContainer) { self.container = container }

    public func run() -> Shell.Output? {
        guard let docker = Shell.find("docker") else { return nil }
        if container.running {
            return Shell.run(docker, ["rm", "-f", container.id])
        } else {
            return Shell.run(docker, ["rm", container.id])
        }
    }
}
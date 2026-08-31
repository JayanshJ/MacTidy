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
/// images. Runs `docker compose -p <name> down --rmi all` first (which removes
/// containers + images that compose knows about), then explicitly `docker rmi -f`
/// for each remaining project image — because `compose down --rmi all` only
/// removes images when their containers still exist. If the containers were
/// already removed (the common "project won't delete" bug), compose down is a
/// no-op and the images would survive without the explicit rmi pass.
/// Volumes are preserved by default; pass `removeVolumes: true` to also remove
/// named volumes (destructive for DBs).
public struct DockerComposeDownAction: ShellAction {
    public let id = UUID()
    public let project: DockerComposeProject
    public let removeVolumes: Bool
    public var displayName: String { "Compose project \(project.name)" }
    public var commandSummary: String {
        var cmd = "docker compose -p \(project.name) down --rmi all"
        if removeVolumes { cmd += " --volumes" }
        // Show the per-image rmi commands too so the user sees the full plan.
        for img in project.images {
            cmd += " && docker rmi -f \(img.id)"
        }
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
        // 1. compose down — stops containers, removes them, and removes images
        //    that compose can see (only when containers exist for them).
        var args = ["compose", "-p", project.name, "down", "--rmi", "all"]
        if removeVolumes { args.append("--volumes") }
        let downResult = Shell.run(docker, args)
        // 2. Explicitly rmi each project image. compose down leaves images
        //    behind when their containers are already gone (the "project won't
        //    delete" bug). This pass guarantees the images are removed.
        var combinedStdout = downResult?.stdout ?? ""
        var combinedStderr = downResult?.stderr ?? ""
        var anyFailed = false
        for img in project.images {
            let rmiResult = Shell.run(docker, ["rmi", "-f", img.id])
            if let r = rmiResult {
                if !r.stdout.isEmpty { combinedStdout += r.stdout }
                if !r.stderr.isEmpty { combinedStderr += r.stderr }
                if !r.succeeded { anyFailed = true }
            }
        }
        // compose down's exit code is 0 even when it's a no-op; the rmi pass
        // is the real indicator of success. If any rmi failed but compose down
        // succeeded, report partial success (exit 0) only when images were
        // actually removed.
        let exitCode: Int32 = anyFailed ? 1 : 0
        return Shell.Output(stdout: combinedStdout, stderr: combinedStderr, exitCode: exitCode)
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
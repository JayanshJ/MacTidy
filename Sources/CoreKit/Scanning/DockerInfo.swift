import Foundation

/// Docker layers live inside the VM disk image — trashing files on the host
/// can't reclaim them. We only *display* what Docker reports and hand the
/// user the exact prune command to run themselves.
public enum DockerInfo {
    public static let pruneCommand = "docker system prune"

    public struct Usage: Sendable {
        /// Raw `docker system df` table, shown verbatim.
        public let table: String
    }

    /// nil when Docker isn't installed or the daemon isn't running.
    public static func usage() -> Usage? {
        guard let docker = Shell.find("docker"),
              let output = Shell.run(docker, ["system", "df"]),
              output.succeeded,
              !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return Usage(table: output.stdout)
    }
}

import Foundation

/// Archives a project as a zip, leaving out build output (it regenerates).
/// Read-only on the source: it only *creates* a zip and verifies it. Moving
/// the project to the Trash afterwards is the caller's job and goes through
/// the normal `DeletionPlan → SafePathPolicy → Trasher` path.
public enum ProjectArchiver {
    public enum Failure: Error, CustomStringConvertible {
        case zipFailed(String)
        case verifyFailed(String)

        public var description: String {
            switch self {
            case .zipFailed(let m): "Couldn't create the archive: \(m)"
            case .verifyFailed(let m): "The archive didn't pass verification: \(m)"
            }
        }
    }

    /// Zips `project` into `directory` as "<name> <yyyy-MM-dd>.zip", leaving
    /// out each path in `excluding` (absolute, inside the project). Symlinks
    /// are stored as links. Throws if zipping or `unzip -t` fails; a partial
    /// zip is moved to the Trash, never left looking like a good archive.
    public static func archive(_ project: URL, excluding: [URL], into directory: URL, now: Date = .now) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let zip = uniqueURL(in: directory, base: "\(project.lastPathComponent) \(day(now))")

        let name = project.lastPathComponent
        let root = project.resolvingSymlinksInPath().path
        var args = ["-r", "-q", "-y", zip.path, name]
        let relative = excluding.compactMap { url -> String? in
            let p = url.resolvingSymlinksInPath().path
            return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : nil
        }
        if !relative.isEmpty {
            args.append("-x")
            for rel in relative { args += ["\(name)/\(rel)/*", "\(name)/\(rel)/"] }
        }

        let zipped = run("/usr/bin/zip", args, in: project.deletingLastPathComponent())
        guard zipped.status == 0 else {
            discard(zip)
            throw Failure.zipFailed(zipped.message)
        }
        let tested = run("/usr/bin/unzip", ["-tqq", zip.path], in: directory)
        guard tested.status == 0 else {
            discard(zip)
            throw Failure.verifyFailed(tested.message)
        }
        return zip
    }

    static func uniqueURL(in dir: URL, base: String) -> URL {
        var candidate = dir.appending(path: base + ".zip")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: "\(base) \(n).zip")
            n += 1
        }
        return candidate
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func discard(_ zip: URL) {
        if FileManager.default.fileExists(atPath: zip.path) { _ = try? Trasher.trash(zip) }
    }

    private static func run(_ tool: String, _ args: [String], in cwd: URL) -> (status: Int32, message: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus, message.isEmpty ? "exit \(p.terminationStatus)" : message)
    }
}

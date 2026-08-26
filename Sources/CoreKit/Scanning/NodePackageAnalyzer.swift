import Foundation

/// Analysis of one Node project's `node_modules` against its `package.json`.
/// Reports **orphaned** packages: physically in `node_modules` but NOT
/// declared in `package.json` deps/devDeps — exactly what `npm prune` removes,
/// safe, keeps the project working. (A previous "declared-but-unused"
/// heuristic was removed: it was false-positive-prone — dynamic imports,
/// polyfill-only deps, build plugins — and added noise without a safe action.)
public struct NodeProjectAnalysis: Identifiable, Sendable, Hashable {
    public let projectDir: URL
    /// Orphaned packages — safe to remove via `npm prune`.
    public let orphaned: [String]
    public let totalInstalledPackages: Int
    /// Bytes of the whole node_modules dir (reclaimable only by trashing it).
    public let nodeModulesBytes: Int64

    public var id: String { projectDir.path }
    public var orphanedBytes: Int64 { 0 } // per-package sizing is unreliable; we report the whole dir

    public init(projectDir: URL, orphaned: [String],
                totalInstalledPackages: Int, nodeModulesBytes: Int64) {
        self.projectDir = projectDir
        self.orphaned = orphaned
        self.totalInstalledPackages = totalInstalledPackages
        self.nodeModulesBytes = nodeModulesBytes
    }

    public var hasFindings: Bool { !orphaned.isEmpty }
}

/// Scans Node projects for orphaned packages. Read-only — the safe reclaim
/// action (`npm prune`) is offered by the UI, never run silently. Critically,
/// this never recommends trashing individual packages out of a live
/// `node_modules`; npm expects that tree to be coherent.
public enum NodePackageAnalyzer {
    /// Analyze a single Node project (a dir containing both `package.json`
    /// and `node_modules`). Returns nil if it's not a Node project.
    public static func analyze(_ projectDir: URL) -> NodeProjectAnalysis? {
        let fm = FileManager.default
        let pkgURL = projectDir.appending(path: "package.json")
        let nmDir = projectDir.appending(path: "node_modules")
        guard fm.fileExists(atPath: pkgURL.path),
              fm.fileExists(atPath: nmDir.path) else { return nil }

        let declared = readDeclaredDeps(at: pkgURL)
        let installed = listTopLevelPackages(in: nmDir)

        // Orphaned: installed top-level packages not in declared deps.
        let declaredSet = Set(declared.keys)
        let orphaned = installed.filter { !declaredSet.contains($0) }

        let total = installed.count
        let bytes = DiskScanner.allocatedSize(of: nmDir)
        return NodeProjectAnalysis(
            projectDir: projectDir,
            orphaned: orphaned,
            totalInstalledPackages: total,
            nodeModulesBytes: bytes
        )
    }

    /// Finds Node projects (dirs with both package.json + node_modules) under
    /// the given roots, skipping nested node_modules so a parent project
    /// isn't double-counted with its workspace children.
    public static func findProjects(under roots: [URL]) -> [URL] {
        var projects: [URL] = []
        let fm = FileManager.default
        for root in roots {
            walk(root, fm: fm, into: &projects)
        }
        return projects
    }

    private static func walk(_ dir: URL, fm: FileManager, into projects: inout [URL]) {
        // Stop descending once we hit a Node project — its nested node_modules
        // belong to it (or a workspace), not separate projects.
        let pkg = dir.appending(path: "package.json")
        let nm = dir.appending(path: "node_modules")
        if fm.fileExists(atPath: pkg.path) && fm.fileExists(atPath: nm.path) {
            projects.append(dir)
            return
        }
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                // Skip hidden + the usual heavy/irrelevant dirs.
                let name = entry.lastPathComponent
                if name.hasPrefix(".") || name == "node_modules" { continue }
                walk(entry, fm: fm, into: &projects)
            }
        }
    }

    // MARK: - package.json deps

    private static func readDeclaredDeps(at pkgURL: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: pkgURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var deps: [String: String] = [:]
        for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            if let section = json[key] as? [String: String] {
                deps.merge(section) { _, new in new }
            }
        }
        return deps
    }

    // MARK: - top-level node_modules packages

    private static func listTopLevelPackages(in nmDir: URL) -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: nmDir, includingPropertiesForKeys: nil)) ?? []
        var packages: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            if name.hasPrefix("@") {
                // Scoped: each subdir under @scope is a package.
                let scoped = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                for s in scoped where !s.lastPathComponent.hasPrefix(".") {
                    packages.append("\(name)/\(s.lastPathComponent)")
                }
            } else {
                packages.append(name)
            }
        }
        return packages
    }
}
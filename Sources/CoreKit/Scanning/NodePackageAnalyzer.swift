import Foundation

/// Analysis of one Node project's `node_modules` against its `package.json`.
/// Two levels, distinguished by safety:
/// - **Level 1 (orphaned)**: packages physically in `node_modules` but NOT
///   declared in `package.json` deps/devDeps. Exactly what `npm prune`
///   removes — safe, keeps the project working.
/// - **Level 2 (unused)**: packages declared in `package.json` but never
///   imported in source. Heuristic — has false positives from dynamic
///   imports, polyfill-only deps, build plugins. Advisory/suggest-only.
public struct NodeProjectAnalysis: Identifiable, Sendable, Hashable {
    public let projectDir: URL
    /// Orphaned packages (Level 1) — safe to remove via `npm prune`.
    public let orphaned: [String]
    /// Declared-but-unused packages (Level 2) — advisory, may have false
    /// positives. The UI must mark these "heuristic — verify".
    public let unused: [String]
    public let totalInstalledPackages: Int
    /// Bytes of the whole node_modules dir (reclaimable only by trashing it).
    public let nodeModulesBytes: Int64

    public var id: String { projectDir.path }
    public var orphanedBytes: Int64 { 0 } // per-package sizing is unreliable; we report the whole dir

    public init(projectDir: URL, orphaned: [String], unused: [String],
                totalInstalledPackages: Int, nodeModulesBytes: Int64) {
        self.projectDir = projectDir
        self.orphaned = orphaned
        self.unused = unused
        self.totalInstalledPackages = totalInstalledPackages
        self.nodeModulesBytes = nodeModulesBytes
    }

    public var hasFindings: Bool { !orphaned.isEmpty || !unused.isEmpty }
}

/// Scans Node projects for orphaned and unused packages. Read-only — the
/// safe reclaim action (`npm prune`) is offered by the UI, never run silently.
/// Critically, this never recommends trashing individual packages out of a
/// live `node_modules`; npm expects that tree to be coherent.
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
        let imports = scanImports(in: projectDir, excluding: nmDir)

        // Level 1: installed top-level packages not in declared deps.
        let declaredSet = Set(declared.keys)
        let orphaned = installed.filter { !declaredSet.contains($0) }

        // Level 2: declared deps never imported in source. False-positive prone.
        let unused = declared.keys.filter { name in
            !imports.contains(name)
        }

        let total = installed.count
        let bytes = DiskScanner.allocatedSize(of: nmDir)
        return NodeProjectAnalysis(
            projectDir: projectDir,
            orphaned: orphaned,
            unused: Array(unused).sorted(),
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

    // MARK: - import scanning

    /// Naive import/require name extraction from .js/.ts/.jsx/.tsx/.mjs/.cjs
    /// files. Intentionally conservative — only static string-literal imports
    /// are matched, which under-counts (dynamic imports, aliases) and is why
    /// Level 2 is advisory.
    private static func scanImports(in projectDir: URL, excluding nmDir: URL) -> Set<String> {
        let fm = FileManager.default
        var imports = Set<String>()
        let nmPath = nmDir.path
        let exts: Set<String> = ["js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte"]

        func scan(_ dir: URL) {
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if entry.lastPathComponent.hasPrefix(".") { continue }
                        if entry.path == nmPath { continue }
                        scan(entry)
                    } else if exts.contains(entry.pathExtension) {
                        if let content = try? String(contentsOf: entry, encoding: .utf8) {
                            imports.formUnion(extractPackageNames(from: content))
                        }
                    }
                }
            }
        }
        scan(projectDir)
        return imports
    }

    private static let importPattern: NSRegularExpression = {
        // Matches: from "pkg", from 'pkg', require("pkg"), import "pkg"
        // Captures the package name, stripped of subpaths (pkg/sub → pkg or @scope/pkg).
        let pattern = #"(?:from|import|require)\s*[\(\[]?\s*['"`]([^'"`]+)['"`]"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func extractPackageNames(from source: String) -> Set<String> {
        var names = Set<String>()
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in importPattern.matches(in: source, options: [], range: range) {
            let raw = ns.substring(with: match.range(at: 1))
            // Only treat as a package import if it doesn't look like a relative
            // path (./ or ../) or a URL scheme.
            guard !raw.hasPrefix("."), !raw.contains("://") else { continue }
            // Strip subpath: "lodash/fp" → "lodash"; "@scope/pkg/sub" → "@scope/pkg".
            let parts = raw.split(separator: "/")
            if raw.hasPrefix("@") && parts.count >= 2 {
                names.insert("\(parts[0])/\(parts[1])")
            } else if let first = parts.first {
                names.insert(String(first))
            }
        }
        return names
    }
}
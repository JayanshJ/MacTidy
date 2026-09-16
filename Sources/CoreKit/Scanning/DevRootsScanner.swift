import Foundation

extension CategoryScanner {
    /// Single-pass walk of all dev roots that classifies every directory
    /// against ALL build-dir + Python-cache + Unity patterns in one enumeration.
    /// Returns a dictionary keyed by category, so the individual `scan(_:)`
    /// cases for nodeModules, rustTargets, podDirs, swiftBuildDirs,
    /// gradleBuildDirs, mavenTarget, phpVendor, flutterDartTool, jsBuildDirs,
    /// pythonCaches, and unityLibrary all share one walk instead of each
    /// re-walking the entire tree (the old code did 7+ redundant full walks).
    func devRootsScan() async -> [Category: [ScanItem]] {

        // Build-dir targets: (dirName, markers, category).
        let buildTargets: [(String, [String], Category)] = [
            ("node_modules", ["package.json"], .nodeModules),
            ("target", ["Cargo.toml"], .rustTargets),
            ("Pods", ["Podfile"], .podDirs),
            (".build", ["Package.swift"], .swiftBuildDirs),
            ("build", ["build.gradle", "build.gradle.kts"], .gradleBuildDirs),
            ("target", ["pom.xml"], .mavenTarget),  // same name as Rust, different marker
            ("vendor", ["composer.json"], .phpVendor),
            (".dart_tool", ["pubspec.yaml"], .flutterDartTool),
            (".next", ["package.json"], .jsBuildDirs),
            (".nuxt", ["package.json"], .jsBuildDirs),
            (".svelte-kit", ["package.json"], .jsBuildDirs),
            (".turbo", ["package.json"], .jsBuildDirs),
            (".output", ["package.json"], .jsBuildDirs),
        ]
        // Python cache dirs: always included (no marker needed).
        let pyAlwaysInclude: Set<String> = ["__pycache__", ".pytest_cache", ".tox", ".ipynb_checkpoints"]
        let venvMarkers = ["pyproject.toml", "requirements.txt", "setup.py"]
        let skipDirs: Set<String> = [".git", "node_modules", "target", "build", ".build", "DerivedData"]

        var results: [Category: [ScanItem]] = [:]
        let fm = FileManager.default
        var pending: [(url: URL, cat: Category, detail: String, modified: Date?)] = []

        for root in devRoots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
                ) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                let dirName = url.lastPathComponent
                if dirName == ".git" || enumerator.level > 12 {
                    enumerator.skipDescendants()
                    continue
                }

                // Check build-dir targets.
                var matched = false
                for (name, markers, cat) in buildTargets where dirName == name {
                    let parent = url.deletingLastPathComponent()
                    let hasMarker = markers.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
                    if hasMarker {
                        enumerator.skipDescendants()
                        pending.append((url: url, cat: cat, detail: parent.lastPathComponent, modified: values.contentModificationDate))
                        matched = true
                        break
                    } else if name == "node_modules" {
                        enumerator.skipDescendants()
                        matched = true
                        break
                    }
                }
                if matched { continue }

                // Python caches.
                if pyAlwaysInclude.contains(dirName) {
                    enumerator.skipDescendants()
                    pending.append((url: url, cat: .pythonCaches, detail: url.deletingLastPathComponent().lastPathComponent, modified: values.contentModificationDate))
                    continue
                }
                if dirName == ".venv" {
                    let parent = url.deletingLastPathComponent()
                    let hasMarker = venvMarkers.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
                    if hasMarker {
                        enumerator.skipDescendants()
                        pending.append((url: url, cat: .pythonCaches, detail: parent.lastPathComponent, modified: values.contentModificationDate))
                        continue
                    }
                }

                // Unity Library (gated on sibling ProjectSettings dir).
                if dirName == "Library" {
                    let parent = url.deletingLastPathComponent()
                    if fm.fileExists(atPath: parent.appending(path: "ProjectSettings").path) {
                        enumerator.skipDescendants()
                        pending.append((url: url, cat: .unityLibrary, detail: parent.lastPathComponent, modified: values.contentModificationDate))
                    }
                }

                // Python caches skip dirs so it doesn't re-walk other categories' trees.
                if skipDirs.contains(dirName) {
                    enumerator.skipDescendants()
                }
            }
        }

        // Calculate sizes in parallel (IMP-12)
        let sized = await withTaskGroup(of: (URL, Category, String, Date?, Int64).self) { group in
            for p in pending {
                group.addTask {
                    let size = DiskScanner.allocatedSize(of: p.url)
                    return (p.url, p.cat, p.detail, p.modified, size)
                }
            }
            var out: [(URL, Category, String, Date?, Int64)] = []
            for await item in group { out.append(item) }
            return out
        }
        for (url, cat, detail, modified, size) in sized where size > 0 {
            results[cat, default: []].append(ScanItem(
                url: url,
                sizeBytes: size,
                isDirectory: true,
                category: cat,
                detail: detail,
                lastModified: modified
            ))
        }

        // Sort each category's items by size descending.
        for (cat, items) in results {
            results[cat] = items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
        return results
    }

    /// Finds build directories (node_modules, Rust target/, Pods/, .build/,
    /// Gradle build/) under the dev roots. One or more sibling marker files
    /// (package.json, Cargo.toml, Podfile, …) must exist so a random folder
    /// that happens to share the name isn't suggested. `category` labels the
    /// resulting items; `detail` carries the owning project name and
    /// `lastModified` the last build time so the user can judge activity.
    func buildDirs(
        named name: String,
        siblingMarkers: [String],
        category: Category
    ) -> [ScanItem] {
        let fm = FileManager.default
        var results: [ScanItem] = []
        for root in devRoots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
                ) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                let dirName = url.lastPathComponent
                if dirName == ".git" || enumerator.level > 12 {
                    enumerator.skipDescendants()
                    continue
                }
                guard dirName == name else { continue }

                let parent = url.deletingLastPathComponent()
                let hasMarker = siblingMarkers.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
                if hasMarker {
                    enumerator.skipDescendants()
                    results.append(ScanItem(
                        url: url,
                        sizeBytes: DiskScanner.allocatedSize(of: url),
                        isDirectory: true,
                        category: category,
                        detail: parent.lastPathComponent,
                        lastModified: values.contentModificationDate
                    ))
                } else if name == "node_modules" {
                    // Not a real npm install dir, but still never worth walking.
                    enumerator.skipDescendants()
                }
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Python bytecode caches and virtualenvs under the dev roots.
    /// `__pycache__`, `.pytest_cache`, `.ipynb_checkpoints` are always included
    /// (regenerable, always safe). `.tox` is included too (regenerable via
    /// `tox`, but rebuilding runs the whole matrix — the category is
    /// suggest-only anyway). `.venv` is included only when a sibling project
    /// marker (`pyproject.toml`, `requirements.txt`, or `setup.py`) confirms
    /// it's a project virtualenv — a random `.venv` without one is left alone.
    /// Skips `.git`, `node_modules`, `target`, `build`, `.build`, `DerivedData`
    /// so it never re-walks trees other categories already surface.
    func pythonCaches() -> [ScanItem] {
        let fm = FileManager.default
        let venvMarkers = ["pyproject.toml", "requirements.txt", "setup.py"]
        let alwaysInclude: Set<String> = ["__pycache__", ".pytest_cache", ".tox", ".ipynb_checkpoints"]
        let skipDirs: Set<String> = [".git", "node_modules", "target", "build", ".build", "DerivedData"]
        var results: [ScanItem] = []
        for root in devRoots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
                ) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                let dirName = url.lastPathComponent
                if skipDirs.contains(dirName) || enumerator.level > 12 {
                    enumerator.skipDescendants()
                    continue
                }

                if alwaysInclude.contains(dirName) {
                    results.append(ScanItem(
                        url: url,
                        sizeBytes: DiskScanner.allocatedSize(of: url),
                        isDirectory: true,
                        category: .pythonCaches,
                        detail: url.deletingLastPathComponent().lastPathComponent,
                        lastModified: values.contentModificationDate
                    ))
                    enumerator.skipDescendants()
                } else if dirName == ".venv" {
                    let parent = url.deletingLastPathComponent()
                    let hasMarker = venvMarkers.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
                    if hasMarker {
                        enumerator.skipDescendants()
                        results.append(ScanItem(
                            url: url,
                            sizeBytes: DiskScanner.allocatedSize(of: url),
                            isDirectory: true,
                            category: .pythonCaches,
                            detail: parent.lastPathComponent,
                            lastModified: values.contentModificationDate
                        ))
                    }
                }
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// JS framework build output dirs under the dev roots: `.next`, `.nuxt`,
    /// `.svelte-kit`, `.turbo`, `.output` — each with a sibling `package.json`
    /// so a coincidentally-named folder isn't suggested. Regenerable via the
    /// framework's build command. Concatenates `buildDirs` results across
    /// the dir names; all items are labeled `.jsBuildDirs`.
    func jsBuildDirs() -> [ScanItem] {
        let names = [".next", ".nuxt", ".svelte-kit", ".turbo", ".output"]
        var items: [ScanItem] = []
        for name in names {
            items.append(contentsOf: buildDirs(
                named: name, siblingMarkers: ["package.json"], category: .jsBuildDirs))
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Unity's imported-asset cache: a `Library/` dir under a Unity project,
    /// gated on a sibling `ProjectSettings/` dir (the reliable Unity-project
    /// signal — `Assets/` alone is too generic). Suggest-only: rebuilding
    /// re-imports every asset, which can be slow.
    func unityLibrary() -> [ScanItem] {
        let fm = FileManager.default
        var results: [ScanItem] = []
        for root in devRoots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
                ) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                let dirName = url.lastPathComponent
                if dirName == ".git" || enumerator.level > 12 {
                    enumerator.skipDescendants()
                    continue
                }
                guard dirName == "Library" else { continue }
                let parent = url.deletingLastPathComponent()
                // Gate on a sibling ProjectSettings dir — the reliable marker
                // that this folder belongs to a Unity project (not a random
                // folder named "Library").
                guard fm.fileExists(atPath: parent.appending(path: "ProjectSettings").path) else {
                    enumerator.skipDescendants()
                    continue
                }
                enumerator.skipDescendants()
                results.append(ScanItem(
                    url: url,
                    sizeBytes: DiskScanner.allocatedSize(of: url),
                    isDirectory: true,
                    category: .unityLibrary,
                    detail: parent.lastPathComponent,
                    lastModified: values.contentModificationDate
                ))
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }
}

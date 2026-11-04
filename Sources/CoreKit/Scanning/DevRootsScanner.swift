import Foundation

extension CategoryScanner {
    /// Every category `devRootsScan` answers. Its result has a key for each,
    /// empty when nothing was found, so a cache hit never falls back to a
    /// per-category re-walk of the dev roots.
    static let devRootsCategories: Set<Category> = [
        .nodeModules, .rustTargets, .podDirs, .swiftBuildDirs, .gradleBuildDirs,
        .mavenTarget, .phpVendor, .flutterDartTool, .jsBuildDirs, .pythonCaches,
        .unityLibrary,
    ]

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

        var results = Dictionary(uniqueKeysWithValues: Self.devRootsCategories.map { ($0, [ScanItem]()) })
        let fm = FileManager.default
        var pending: [(url: URL, cat: Category, detail: String, modified: Date?, finding: String?)] = []

        for root in Self.distinctRoots(devRoots) {
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
                    let hasMarker = BuildOutput.hasSwiftMarker(parent: parent, markers: markers)
                    if hasMarker {
                        enumerator.skipDescendants()
                        pending.append((url: url, cat: cat, detail: parent.lastPathComponent, modified: values.contentModificationDate,
                            finding: dirName == ".build" && !fm.fileExists(atPath: parent.appending(path: "Package.swift").path) ? BuildOutput.xcodeFinding : nil))
                        matched = true
                        break
                    } else if name == "node_modules" {
                        enumerator.skipDescendants()
                        matched = true
                        break
                    }
                }
                if matched { continue }

                if BuildOutput.isIgnored(url) {
                    enumerator.skipDescendants()
                    pending.append((url: url, cat: .jsBuildDirs, detail: url.deletingLastPathComponent().lastPathComponent, modified: values.contentModificationDate, finding: BuildOutput.finding))
                    continue
                }

                // Python caches.
                if pyAlwaysInclude.contains(dirName) {
                    enumerator.skipDescendants()
                    pending.append((url: url, cat: .pythonCaches, detail: url.deletingLastPathComponent().lastPathComponent, modified: values.contentModificationDate, finding: nil))
                    continue
                }
                if dirName == ".venv" {
                    let parent = url.deletingLastPathComponent()
                    let hasMarker = venvMarkers.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
                    if hasMarker {
                        enumerator.skipDescendants()
                        pending.append((url: url, cat: .pythonCaches, detail: parent.lastPathComponent, modified: values.contentModificationDate, finding: nil))
                        continue
                    }
                }

                // Unity Library (gated on sibling ProjectSettings dir).
                if dirName == "Library" {
                    let parent = url.deletingLastPathComponent()
                    if fm.fileExists(atPath: parent.appending(path: "ProjectSettings").path) {
                        enumerator.skipDescendants()
                        pending.append((url: url, cat: .unityLibrary, detail: parent.lastPathComponent, modified: values.contentModificationDate, finding: nil))
                    }
                }

                // Python caches skip dirs so it doesn't re-walk other categories' trees.
                if skipDirs.contains(dirName) {
                    enumerator.skipDescendants()
                }
            }
        }

        // Calculate sizes in parallel (IMP-12)
        let sized = await withTaskGroup(of: (URL, Category, String, Date?, String?, Int64).self) { group in
            for p in pending {
                group.addTask {
                    let size = DiskScanner.allocatedSize(of: p.url)
                    return (p.url, p.cat, p.detail, p.modified, p.finding, size)
                }
            }
            var out: [(URL, Category, String, Date?, String?, Int64)] = []
            for await item in group { out.append(item) }
            return out
        }
        for (url, cat, detail, modified, finding, size) in sized where size > 0 {
            results[cat, default: []].append(ScanItem(
                url: url,
                sizeBytes: size,
                isDirectory: true,
                category: cat,
                detail: detail,
                lastModified: modified,
                finding: finding
            ))
        }

        // Sort each category's items by size descending.
        for (cat, items) in results {
            results[cat] = items.sorted { BuildOutput.rank($0) > BuildOutput.rank($1) }
        }
        return results
    }

}

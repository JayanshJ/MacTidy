import Foundation
import Testing
@testable import CoreKit

/// Node package analysis — orphaned-package detection (what `npm prune`
/// removes). Builds a fake Node project in a temp dir so the matching logic
/// is exercised for real. (The previous "declared-but-unused" heuristic was
/// removed as false-positive-prone; these tests cover the orphaned path only.)
@Suite("NodePackageAnalyzer")
struct NodePackageAnalyzerTests {
    private func makeProject() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mactidy-node-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // package.json declares three deps.
        let pkg: [String: Any] = [
            "name": "testproj",
            "dependencies": [
                "lodash": "^4.0.0",
                "moment": "^2.0.0",
                "express": "^4.0.0",
            ],
        ]
        let pkgData = try JSONSerialization.data(withJSONObject: pkg)
        try pkgData.write(to: dir.appending(path: "package.json"))

        // node_modules with: 3 declared + 1 orphaned (leftpad, not declared).
        let nm = dir.appending(path: "node_modules")
        for name in ["lodash", "moment", "express", "leftpad"] {
            try fm.createDirectory(at: nm.appending(path: name), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: nm.appending(path: "\(name)/index.js"))
        }
        return dir
    }

    @Test func detectsOrphanedPackages() throws {
        let project = try makeProject()
        let analysis = try #require(NodePackageAnalyzer.analyze(project))

        // leftpad is orphaned (installed, not declared).
        #expect(analysis.orphaned.contains("leftpad"))
        // Declared packages are not flagged as orphaned.
        #expect(!analysis.orphaned.contains("lodash"))
        #expect(!analysis.orphaned.contains("express"))

        // Total installed = 4 top-level packages.
        #expect(analysis.totalInstalledPackages == 4)
        // No orphaned-package findings until leftpad is removed.
        #expect(analysis.hasFindings == true)
    }

    @Test func cleanProjectHasNoFindings() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mactidy-clean-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg: [String: Any] = ["name": "cleanproj", "dependencies": ["lodash": "^4.0.0"]]
        try JSONSerialization.data(withJSONObject: pkg).write(to: dir.appending(path: "package.json"))
        let nm = dir.appending(path: "node_modules/lodash")
        try fm.createDirectory(at: nm, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nm.appending(path: "index.js"))
        let analysis = try #require(NodePackageAnalyzer.analyze(dir))
        #expect(analysis.orphaned.isEmpty)
        #expect(analysis.hasFindings == false)
    }

    @Test func nonNodeDirReturnsNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mactidy-notnode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(NodePackageAnalyzer.analyze(dir) == nil)
    }

    @Test func scopedPackagesListedCorrectly() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mactidy-scoped-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg: [String: Any] = ["name": "s", "dependencies": ["@scope/foo": "^1.0.0"]]
        try JSONSerialization.data(withJSONObject: pkg).write(to: dir.appending(path: "package.json"))
        let nm = dir.appending(path: "node_modules/@scope/foo")
        try fm.createDirectory(at: nm, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nm.appending(path: "index.js"))
        let analysis = try #require(NodePackageAnalyzer.analyze(dir))
        #expect(analysis.totalInstalledPackages == 1)
    }
}
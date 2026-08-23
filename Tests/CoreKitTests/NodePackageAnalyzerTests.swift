import Foundation
import Testing
@testable import CoreKit

/// Node package analysis — the safety-critical distinction between Level 1
/// (orphaned, safe) and Level 2 (unused, advisory). Builds a fake Node
/// project in a temp dir so the matching logic is exercised for real.
@Suite("NodePackageAnalyzer")
struct NodePackageAnalyzerTests {
    private func makeProject() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mactidy-node-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // package.json declares three deps: one used, one unused, one used.
        let pkg: [String: Any] = [
            "name": "testproj",
            "dependencies": [
                "lodash": "^4.0.0",       // used
                "moment": "^2.0.0",       // unused (Level 2)
                "express": "^4.0.0",      // used
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

        // Source that imports lodash and express but NOT moment.
        let src = """
        import _ from 'lodash';
        const app = require('express')();
        export default app;
        """
        try src.write(to: dir.appending(path: "index.js"), atomically: true, encoding: .utf8)

        return dir
    }

    @Test func detectsOrphanedAndUnused() throws {
        let project = try makeProject()
        let analysis = try #require(NodePackageAnalyzer.analyze(project))

        // Level 1: leftpad is orphaned (installed, not declared).
        #expect(analysis.orphaned.contains("leftpad"))
        #expect(!analysis.orphaned.contains("lodash"))

        // Level 2: moment is declared but never imported.
        #expect(analysis.unused.contains("moment"))
        #expect(!analysis.unused.contains("lodash"))
        #expect(!analysis.unused.contains("express"))

        // Total installed = 4 top-level packages.
        #expect(analysis.totalInstalledPackages == 4)
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
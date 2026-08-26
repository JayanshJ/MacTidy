import Foundation
import Testing
@testable import CoreKit

/// `UpdateInstaller` holds the pure, side-effect-free half of `UpdateManager`:
/// app-bundle discovery, bundle verification, and swap-helper script
/// generation. These tests pin the update pipeline's safety contract without
/// launching a `Process` or swapping the running app.
@Suite("UpdateInstaller")
struct UpdateInstallerTests {
    /// Builds a fake `.app` bundle on disk with an executable, an Info.plist
    /// carrying the given bundle id + version, and a Contents/MacOS dir.
    @discardableResult
    private func makeBundle(
        in dir: URL,
        name: String = "MacTidy.app",
        bundleID: String = UpdateInstaller.expectedBundleID,
        version: String = "9.9.9"
    ) throws -> URL {
        let app = dir.appendingPathComponent(name, isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let exe = macos.appendingPathComponent("MacTidy")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: plist)
        return app
    }

    // MARK: - findAppBundle

    @Test func findsBundleAtRoot() throws {
        let staging = try makeTempDir()
        _ = try makeBundle(in: staging, name: "MacTidy.app")
        let found = UpdateInstaller.findAppBundle(in: staging)
        #expect(found?.lastPathComponent == "MacTidy.app")
    }

    @Test func findsBundleOneLevelDeep() throws {
        // A zip that wraps a top folder lands the .app one level deep.
        let staging = try makeTempDir()
        let wrapper = staging.appendingPathComponent("MacTidy-1.0", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        _ = try makeBundle(in: wrapper, name: "MacTidy.app")
        let found = UpdateInstaller.findAppBundle(in: staging)
        #expect(found?.lastPathComponent == "MacTidy.app")
    }

    @Test func findAppBundleReturnsNilWhenNoApp() throws {
        let staging = try makeTempDir()
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("notanapp", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(UpdateInstaller.findAppBundle(in: staging) == nil)
    }

    @Test func findAppBundlePicksFirstAppAtRoot() throws {
        let staging = try makeTempDir()
        _ = try makeBundle(in: staging, name: "Alpha.app")
        _ = try makeBundle(in: staging, name: "Beta.app")
        let found = UpdateInstaller.findAppBundle(in: staging)
        #expect(found?.lastPathComponent == "Alpha.app")
    }

    // MARK: - verifyBundle

    @Test func verifyBundleAcceptsValidNewerBundle() throws {
        let staging = try makeTempDir()
        let app = try makeBundle(in: staging, version: "2.0.0")
        // codesign check injected as "always passes".
        try UpdateInstaller.verifyBundle(
            at: app,
            expectedVersion: UpdateChecker.Version("2.0.0"),
            currentVersion: UpdateChecker.Version("1.5.0"),
            codesignVerify: { _ in Shell.Output(stdout: "", stderr: "", exitCode: 0) }
        )
    }

    @Test func verifyBundleRejectsMissingExecutable() throws {
        let staging = try makeTempDir()
        let app = try makeBundle(in: staging)
        // Remove the executable — no longer a real bundle.
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/MacTidy"))
        #expect(throws: UpdateInstaller.VerificationError.notAppBundle) {
            try UpdateInstaller.verifyBundle(
                at: app,
                expectedVersion: UpdateChecker.Version("2.0.0"),
                currentVersion: UpdateChecker.Version("1.0.0"),
                codesignVerify: { _ in Shell.Output(stdout: "", stderr: "", exitCode: 0) }
            )
        }
    }

    @Test func verifyBundleRejectsWrongBundleID() throws {
        let staging = try makeTempDir()
        let app = try makeBundle(in: staging, bundleID: "com.evil.twin")
        #expect(throws: UpdateInstaller.VerificationError.wrongBundle) {
            try UpdateInstaller.verifyBundle(
                at: app,
                expectedVersion: UpdateChecker.Version("2.0.0"),
                currentVersion: UpdateChecker.Version("1.0.0"),
                codesignVerify: { _ in Shell.Output(stdout: "", stderr: "", exitCode: 0) }
            )
        }
    }

    @Test func verifyBundleRejectsBadSignature() throws {
        let staging = try makeTempDir()
        let app = try makeBundle(in: staging, version: "2.0.0")
        #expect(throws: UpdateInstaller.VerificationError.signatureInvalid("bad sig")) {
            try UpdateInstaller.verifyBundle(
                at: app,
                expectedVersion: UpdateChecker.Version("2.0.0"),
                currentVersion: UpdateChecker.Version("1.0.0"),
                codesignVerify: { _ in Shell.Output(stdout: "", stderr: "bad sig", exitCode: 1) }
            )
        }
    }

    @Test func verifyBundleRejectsDowngrade() throws {
        let staging = try makeTempDir()
        // Downloaded 1.0.0 while running 2.0.0 — must refuse.
        let app = try makeBundle(in: staging, version: "1.0.0")
        #expect(throws: UpdateInstaller.VerificationError.wrongVersion(found: "1.0.0")) {
            try UpdateInstaller.verifyBundle(
                at: app,
                expectedVersion: UpdateChecker.Version("1.0.0"),
                currentVersion: UpdateChecker.Version("2.0.0"),
                codesignVerify: { _ in Shell.Output(stdout: "", stderr: "", exitCode: 0) }
            )
        }
    }

    @Test func verifyBundleRejectsVersionMismatch() throws {
        // Manifest said 2.0.0 but the bundle says 2.1.0 — refuse, it's not what
        // was advertised (could be a tampered or mismatched asset).
        let staging = try makeTempDir()
        let app = try makeBundle(in: staging, version: "2.1.0")
        #expect(throws: UpdateInstaller.VerificationError.wrongVersion(found: "2.1.0")) {
            try UpdateInstaller.verifyBundle(
                at: app,
                expectedVersion: UpdateChecker.Version("2.0.0"),
                currentVersion: UpdateChecker.Version("1.0.0"),
                codesignVerify: { _ in Shell.Output(stdout: "", stderr: "", exitCode: 0) }
            )
        }
    }

    // MARK: - swapHelperScript

    @Test func swapHelperScriptUsesRmRfNotFinder() {
        let script = UpdateInstaller.swapHelperScript(
            newAppURL: URL(fileURLWithPath: "/tmp/new/MacTidy.app"),
            installURL: URL(fileURLWithPath: "/Applications/MacTidy.app"),
            currentPID: 4242
        )
        // The whole point of the v1.6.3 fix: the helper must `rm -rf` the old
        // bundle, NOT `osascript … Finder delete` (which hung for minutes).
        #expect(script.contains("rm -rf \"$DEST\"") == true)
        #expect(script.contains("osascript") == false)
        #expect(script.contains("Finder") == false)
    }

    @Test func swapHelperScriptMovesNewBundleAndStripsQuarantine() {
        let script = UpdateInstaller.swapHelperScript(
            newAppURL: URL(fileURLWithPath: "/tmp/new/MacTidy.app"),
            installURL: URL(fileURLWithPath: "/Applications/MacTidy.app"),
            currentPID: 99
        )
        #expect(script.contains("mv \"$NEW_APP\" \"$DEST\"") == true)
        #expect(script.contains("xattr -dr com.apple.quarantine \"$DEST\"") == true)
        #expect(script.contains("open \"$DEST\"") == true)        // relaunch
        #expect(script.contains("rm -f \"$0\"") == true)          // self-delete
    }

    @Test func swapHelperScriptWaitsForOwnPID() {
        let script = UpdateInstaller.swapHelperScript(
            newAppURL: URL(fileURLWithPath: "/tmp/new/MacTidy.app"),
            installURL: URL(fileURLWithPath: "/Applications/MacTidy.app"),
            currentPID: 1337
        )
        // The pid-wait loop must reference the passed pid so the helper only
        // swaps once *this* process is gone.
        #expect(script.contains("kill -0 1337") == true)
    }

    @Test func swapHelperScriptEmbedsPaths() {
        let script = UpdateInstaller.swapHelperScript(
            newAppURL: URL(fileURLWithPath: "/staging/MacTidy.app"),
            installURL: URL(fileURLWithPath: "/Applications/MacTidy.app"),
            currentPID: 1
        )
        #expect(script.contains("NEW_APP=\"/staging/MacTidy.app\"") == true)
        #expect(script.contains("DEST=\"/Applications/MacTidy.app\"") == true)
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mactidy-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
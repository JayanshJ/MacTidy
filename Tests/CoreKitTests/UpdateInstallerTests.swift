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

    @Test func swapHelperScriptNeverDeletesAndAvoidsFinder() {
        let script = UpdateInstaller.swapHelperScript(
            newAppURL: URL(fileURLWithPath: "/tmp/new/MacTidy.app"),
            installURL: URL(fileURLWithPath: "/Applications/MacTidy.app"),
            currentPID: 4242
        )
        // The old bundle is moved aside, so a failed install can put it back.
        // Finder was dropped in v1.6.3 because `delete` hung for minutes.
        #expect(script.contains("mv \"$DEST\" \"$BACKUP\"") == true)
        #expect(script.contains("rm ") == false)
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

    // MARK: - Running the helper

    /// Runs the real script against fake bundles in a temp folder.
    private func runHelper(new: URL, dest: URL, in dir: URL) throws -> (status: Int32, failure: String?) {
        let marker = dir.appending(path: "failed.txt")
        let script = dir.appending(path: "swap.sh")
        try UpdateInstaller.swapHelperScript(newAppURL: new, installURL: dest, currentPID: 999_999, relaunch: false,
                                             logURL: dir.appending(path: "update.log"), failureMarkerURL: marker)
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, try? String(contentsOf: marker, encoding: .utf8))
    }

    private func sign(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", app.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func version(of app: URL) -> String? {
        NSDictionary(contentsOfFile: app.appending(path: "Contents/Info.plist").path)?["CFBundleShortVersionString"] as? String
    }

    @Test func helperInstallsTheNewBundleAndKeepsTheOldAside() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stagingDir = dir.appending(path: "staging")
        let installDir = dir.appending(path: "Applications")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let new = try makeBundle(in: stagingDir, version: "2.0.0")
        let dest = try makeBundle(in: installDir, version: "1.0.0")
        try sign(new)

        let result = try runHelper(new: new, dest: dest, in: dir)

        #expect(result.status == 0)
        #expect(result.failure == nil)
        #expect(version(of: dest) == "2.0.0")
        #expect(version(of: stagingDir.appending(path: "MacTidy-previous.app")) == "1.0.0")
    }

    @Test func helperPutsTheOldBundleBackWhenTheNewOneIsBad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stagingDir = dir.appending(path: "staging")
        let installDir = dir.appending(path: "Applications")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let new = try makeBundle(in: stagingDir, version: "2.0.0")   // unsigned
        let dest = try makeBundle(in: installDir, version: "1.0.0")

        let result = try runHelper(new: new, dest: dest, in: dir)

        #expect(result.status == 1)
        #expect(result.failure != nil)
        #expect(version(of: dest) == "1.0.0")
    }

    @Test func helperKeepsTheOldBundleWhenItCannotBeMoved() throws {
        let dir = try makeTempDir()
        let stagingDir = dir.appending(path: "staging")
        let installDir = dir.appending(path: "Applications")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let new = try makeBundle(in: stagingDir, version: "2.0.0")
        let dest = try makeBundle(in: installDir, version: "1.0.0")
        try sign(new)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: installDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installDir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let result = try runHelper(new: new, dest: dest, in: dir)

        #expect(result.status == 1)
        #expect(result.failure?.contains("Permission denied") == true)
        #expect(version(of: dest) == "1.0.0")
        #expect(version(of: new) == "2.0.0")
    }

    @Test func onlyTheInstalledCopyInstallsItself() {
        let installed = URL(fileURLWithPath: "/Applications/MacTidy.app")
        #expect(UpdateInstaller.canInstallAutomatically(runningBundle: installed, installURL: installed))
        #expect(!UpdateInstaller.canInstallAutomatically(
            runningBundle: URL(fileURLWithPath: "/Users/me/Developer/MacTidy/dist/MacTidy.app"), installURL: installed))
    }

    @Test func failureMessagePointsToAppManagementWhenBlocked() {
        #expect(UpdateInstaller.failureMessage("mv: rename: Operation not permitted\n").contains("App Management"))
        #expect(UpdateInstaller.failureMessage("disk full").contains("disk full"))
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mactidy-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
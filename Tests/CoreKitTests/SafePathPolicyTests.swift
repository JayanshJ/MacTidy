import Foundation
import Testing
@testable import CoreKit

@Suite("SafePathPolicy denylist")
struct SafePathPolicyTests {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let policy = SafePathPolicy()

    func rejects(_ path: String, policy: SafePathPolicy? = nil) -> Bool {
        do {
            try (policy ?? self.policy).validate(URL(fileURLWithPath: path))
            return false
        } catch { return true }
    }

    @Test func rejectsSystemPaths() {
        #expect(rejects("/System/Library/CoreServices/Finder.app"))
        #expect(rejects("/bin/ls"))
        #expect(rejects("/sbin/mount"))
        #expect(rejects("/usr/bin/swift"))
        #expect(rejects("/usr/lib/dyld"))
        #expect(rejects("/Library/Apple/System"))
        #expect(rejects("/etc/hosts"))
        #expect(rejects("/"))
    }

    @Test func rejectsCriticalDirectoriesThemselves() {
        #expect(rejects(home.path))
        #expect(rejects(home.appending(path: "Library").path))
        #expect(rejects(home.appending(path: "Library/Caches").path))
        #expect(rejects(home.appending(path: "Downloads").path))
        #expect(rejects("/Applications"))
        #expect(rejects("/Library"))
        #expect(rejects("/Users"))
    }

    @Test func rejectsPersonalFolders() {
        #expect(rejects(home.appending(path: "Documents/taxes.pdf").path))
        #expect(rejects(home.appending(path: "Desktop/screenshot.png").path))
        #expect(rejects(home.appending(path: "Pictures/photo.jpg").path))
        #expect(rejects(home.appending(path: "Movies/film.mp4").path))
        #expect(rejects(home.appending(path: "Music/song.m4a").path))
    }

    @Test func rejectsPathsOutsideAllowedRoots() {
        #expect(rejects("/Volumes/Backup/whatever"))
        #expect(rejects("/opt/other/thing"))
        #expect(rejects("/private/var/db/something"))
    }

    @Test func allowsRealCleanupTargets() throws {
        try policy.validate(home.appending(path: "Library/Caches/com.example.app"))
        try policy.validate(home.appending(path: "Library/Developer/Xcode/DerivedData/Proj-abc"))
        try policy.validate(home.appending(path: "Downloads/old-installer.dmg"))
        try policy.validate(URL(fileURLWithPath: "/Applications/SomeApp.app"))
        try policy.validate(URL(fileURLWithPath: "/usr/local/foo"))
        try policy.validate(URL(fileURLWithPath: "/opt/homebrew/Cellar/something"))
    }

    @Test func extraRootUnlocksPersonalSubfolder() throws {
        let picked = home.appending(path: "Documents/DuplicateScanArea")
        let scoped = SafePathPolicy(extraAllowedRoots: [picked])
        try scoped.validate(picked.appending(path: "copy 2.jpg"))
        // ...but only that subtree; the rest of Documents stays protected.
        #expect(rejects(home.appending(path: "Documents/other.pdf").path, policy: scoped))
    }

    @Test func extraRootCannotUnlockSystemPaths() {
        let evil = SafePathPolicy(extraAllowedRoots: [URL(fileURLWithPath: "/System")])
        #expect(rejects("/System/Library/Kernels/kernel", policy: evil))
    }

    @Test func symlinkEscapingAllowedRootIsRejected() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appending(path: "mactidy-test-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let link = sandbox.appending(path: "sneaky")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System/Library"))

        let scoped = SafePathPolicy(extraAllowedRoots: [sandbox])
        // A regular file in the picked root is fine…
        let regular = sandbox.appending(path: "normal.txt")
        try Data("x".utf8).write(to: regular)
        try scoped.validate(regular)
        // …but the symlink resolves outside it, into /System, and is refused.
        #expect(rejects(link.path, policy: scoped))
    }

    // MARK: - classify

    @Test func classifyMatchesValidate() {
        // For every path, classify and validate must agree: success iff no throw.
        let paths = [
            "/System/Library", "/bin/ls", "/usr/bin/swift", "/etc/hosts", "/",
            home.path, home.appending(path: "Library").path,
            home.appending(path: "Library/Caches/com.example.app").path,
            home.appending(path: "Documents/taxes.pdf").path,
            "/Applications/SomeApp.app", "/opt/homebrew/Cellar/x",
            "/Volumes/Backup/thing", "/usr/local/foo",
        ]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let classified = (try? policy.validate(url)) != nil
            let result: Bool
            switch policy.classify(url) { case .success: result = true; case .failure: result = false }
            #expect(classified == result, "classify/validate disagree on \(path)")
        }
    }

    /// No system path — even deep under a protected root — ever classifies as
    /// success, regardless of how it's spelled. A property-style sweep over
    /// the whole denylist surface.
    @Test(arguments: [
        "/System", "/System/Library", "/System/Library/CoreServices/Finder.app",
        "/bin", "/bin/ls", "/sbin", "/sbin/mount",
        "/usr", "/usr/bin", "/usr/lib/dyld", "/usr/share",
        "/Library/Apple", "/Library/Apple/foo",
        "/etc", "/etc/hosts", "/private/etc", "/private/etc/x",
    ])
    func systemPathsNeverClassifyAsValid(_ path: String) {
        if case .success = policy.classify(URL(fileURLWithPath: path)) {
            Issue.record("system path classified as valid: \(path)")
        }
    }

    @Test func classifyFailureCarriesReason() {
        if case .failure(let violation) = policy.classify(URL(fileURLWithPath: "/System/Library")) {
            #expect(!violation.description.isEmpty)
        } else {
            Issue.record("expected failure")
        }
    }
}

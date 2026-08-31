import Foundation
import Testing
@testable import CoreKit

/// Tests for `ProcessScanner.attribute` (the `.app` roll-up logic), `Shell.find`
/// (the standard-location tool lookup), and `TrashUsage` (the ~/.Trash sizer).
/// These are the safety-critical / pure helpers that previously had no coverage.
@Suite("Untested helpers")
struct UntestedHelpersTests {
    // MARK: - ProcessScanner.attribute

    @Test func attributeExtractsAppNameFromBundlePath() {
        let (name, path) = ProcessScanner.attribute(
            comm: "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
        #expect(name == "Docker")
        // Path is only returned if the .app exists on disk; in a test env it
        // may or may not. The name is the important part.
        _ = path
    }

    @Test func attributeExtractsSpotifyFromHelperPath() {
        let (name, _) = ProcessScanner.attribute(
            comm: "/Applications/Spotify.app/Contents/MacOS/Spotify Helper")
        #expect(name == "Spotify")
    }

    @Test func attributeReturnsBasenameForNonApp() {
        let (name, path) = ProcessScanner.attribute(comm: "/usr/local/bin/node")
        #expect(name == "node")
        #expect(path == nil)
    }

    @Test func attributeReturnsBasenameForBareCommand() {
        let (name, path) = ProcessScanner.attribute(comm: "rapportd")
        #expect(name == "rapportd")
        #expect(path == nil)
    }

    @Test func attributeHandlesNestedAppBundle() {
        let (name, _) = ProcessScanner.attribute(
            comm: "/Applications/Some App.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
        // The FIRST .app ancestor wins (walks up from the leaf), so this
        // should attribute to "Helper", not "Some App".
        #expect(name == "Helper")
    }

    // MARK: - Shell.find

    @Test func shellFindLocatesAlwaysPresentBin() {
        // /bin/ls is always present on macOS.
        let result = Shell.find("ls")
        #expect(result != nil)
        #expect(result == "/bin/ls" || result == "/usr/bin/ls")
    }

    @Test func shellFindReturnsNilForNonexistentTool() {
        let result = Shell.find("this-tool-definitely-does-not-exist-xyz123")
        #expect(result == nil)
    }

    @Test func shellFindChecksStandardLocationsOnly() {
        // `cat` is in /bin, which is one of the standard locations Shell.find
        // checks. It should find it regardless of $PATH.
        let result = Shell.find("cat")
        #expect(result != nil)
    }

    // MARK: - TrashUsage

    @Test func trashURLIsInHomeDotTrash() {
        let url = TrashUsage.trashURL
        #expect(url.path.hasSuffix("/.Trash"))
    }

    @Test func trashTotalBytesIsNonNegative() {
        // The Trash may be empty or have items; either way it should be >= 0.
        let bytes = TrashUsage.totalBytes()
        #expect(bytes >= 0)
    }
}
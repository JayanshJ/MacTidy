import Testing
import Foundation
@testable import CoreKit

@Suite("Update checker")
struct UpdateCheckerTests {
    // MARK: - Version comparison

    @Test func parsesSemverStrings() {
        #expect(UpdateChecker.Version("1.4").numeric == [1, 4])
        #expect(UpdateChecker.Version("v1.5.2").numeric == [1, 5, 2])
        #expect(UpdateChecker.Version("1.10.0").numeric == [1, 10, 0])
    }

    @Test func rawStripsVPrefix() {
        // The views render `Text("v\(version.raw)")`, so `raw` must NOT
        // carry its own leading `v`/`V` — otherwise it shows as "vv1.9.0".
        #expect(UpdateChecker.Version("v1.9.0").raw == "1.9.0")
        #expect(UpdateChecker.Version("V1.9.0").raw == "1.9.0")
        #expect(UpdateChecker.Version("1.9.0").raw == "1.9.0")
    }

    @Test func newerVersionIsGreaterThan() {
        #expect(UpdateChecker.Version("1.5") > UpdateChecker.Version("1.4"))
        #expect(UpdateChecker.Version("1.10") > UpdateChecker.Version("1.9"))
        #expect(UpdateChecker.Version("2.0") > UpdateChecker.Version("1.99"))
    }

    @Test func equalAndOlderVersions() {
        #expect(UpdateChecker.Version("1.4") == UpdateChecker.Version("1.4"))
        #expect(!(UpdateChecker.Version("1.3") > UpdateChecker.Version("1.4")))
        #expect(!(UpdateChecker.Version("1.4") > UpdateChecker.Version("1.4")))
    }

    @Test func differentLengthVersionsCompare() {
        // 1.4 == 1.4.0 for comparison purposes.
        #expect(UpdateChecker.Version("1.4") == UpdateChecker.Version("1.4.0"))
        #expect(UpdateChecker.Version("1.4.1") > UpdateChecker.Version("1.4"))
    }

    // MARK: - Manifest parsing

    @Test func parsesLatestReleaseManifest() throws {
        let json = """
        {
          "tag_name": "v1.5",
          "name": "MacTidy 1.5",
          "body": "Added Docker cleanup.\\nFixed node_modules grouping.",
          "assets": [
            {"name": "MacTidy.app.zip", "browser_download_url": "https://example.com/MacTidy.app.zip", "size": 4500000},
            {"name": "SOURCE.txt", "browser_download_url": "https://example.com/SOURCE.txt", "size": 12}
          ]
        }
        """
        let manifest = try #require(UpdateChecker.parseRelease(json: json))
        #expect(manifest.version.numeric == [1, 5])
        #expect(manifest.releaseName == "MacTidy 1.5")
        #expect(manifest.notes.contains("Docker cleanup"))
        #expect(manifest.downloadURL?.absoluteString == "https://example.com/MacTidy.app.zip")
        #expect(manifest.downloadSize == 4_500_000)
    }

    @Test func releaseWithoutZipAssetHasNilDownloadURL() throws {
        let json = """
        {
          "tag_name": "v1.5",
          "name": "MacTidy 1.5",
          "body": "",
          "assets": [{"name": "SOURCE.txt", "browser_download_url": "https://example.com/SOURCE.txt", "size": 12}]
        }
        """
        let manifest = try #require(UpdateChecker.parseRelease(json: json))
        #expect(manifest.version.numeric == [1, 5])
        #expect(manifest.downloadURL == nil)
    }

    @Test func malformedJSONReturnsNil() {
        #expect(UpdateChecker.parseRelease(json: "not json") == nil)
        #expect(UpdateChecker.parseRelease(json: "{}") == nil)
    }

    @Test func isUpdateAvailableComparAgainstCurrent() {
        let m = UpdateChecker.ReleaseManifest(
            version: UpdateChecker.Version("1.5"),
            releaseName: "MacTidy 1.5",
            notes: "",
            htmlURL: URL(string: "https://github.com/JayanshJ/MacTidy/releases/latest")!,
            downloadURL: nil,
            downloadSize: 0
        )
        #expect(UpdateChecker.isUpdateAvailable(manifest: m, current: "1.4") == true)
        #expect(UpdateChecker.isUpdateAvailable(manifest: m, current: "1.5") == false)
        #expect(UpdateChecker.isUpdateAvailable(manifest: m, current: "1.6") == false)
    }
}
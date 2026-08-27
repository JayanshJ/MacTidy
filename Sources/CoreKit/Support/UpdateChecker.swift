import Foundation

/// Self-update support: fetches the latest GitHub release and decides whether
/// it's newer than the running app. The actual download + in-place replace
/// lives in the app layer (`UpdateManager`); this file is the pure, testable
/// core — manifest parsing and version comparison, with no network.
///
/// Release channel: GitHub Releases on `JayanshJ/MacTidy`. The latest release's
/// `tag_name` (e.g. `v1.5`) is the new version; an asset named
/// `MacTidy.app.zip` is the update payload. There is no appcast file to
/// maintain — a GitHub release is the manifest.
public enum UpdateChecker {
    /// The GitHub repo to query. Hardcoded — this is a personal-use app with
    /// one distribution channel.
    public static let repoOwner = "JayanshJ"
    public static let repoName = "MacTidy"

    /// Latest-release API endpoint (HTTPS, unauthenticated; 60 req/hr is far
    /// more than a launch-time check needs).
    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

    /// The browser URL for the latest release, used when no downloadable zip
    /// asset is attached (fall back to "open the release page").
    public static var latestReleasePageURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
    }

    /// The asset filename that carries the update payload.
    public static let assetName = "MacTidy.app.zip"

    // MARK: - Version

    /// A dot-separated semantic version, compared numerically (1.10 > 1.9).
    /// A leading `v` is tolerated. Non-numeric components are ignored.
    public struct Version: Comparable, Sendable {
        public let raw: String
        public let numeric: [Int]

        public init(_ raw: String) {
            var s = raw
            // Store the version with any leading `v`/`V` prefix stripped so
            // `raw` is the clean numeric form ("1.9.0", not "v1.9.0"). The
            // views render `Text("v\(version.raw)")` — a raw that still
            // carried the prefix would show as "vv1.9.0".
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            self.raw = s
            // Strip any prerelease suffix after the first non-version char
            // (e.g. "1.5-beta" → [1,5]); keep numeric dot components only.
            self.numeric = Version.parse(s)
        }

        private static func parse(_ s: String) -> [Int] {
            // Take everything up to the first `-`/`+`/space, then split on '.'.
            let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first ?? ""
            return core.split(separator: ".").compactMap { Int($0) }
        }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            // Pad to equal length, compare component-wise. Missing components
            // are treated as 0, so 1.4 == 1.4.0.
            let max = Swift.max(lhs.numeric.count, rhs.numeric.count)
            for i in 0..<max {
                let l = i < lhs.numeric.count ? lhs.numeric[i] : 0
                let r = i < rhs.numeric.count ? rhs.numeric[i] : 0
                if l != r { return l < r }
            }
            return false
        }

        /// Consistent with `<`: equal versions compare component-wise with
        /// zero-padding, so `1.4` == `1.4.0`. Overrides the synthesized
        /// field-wise equality that would otherwise treat them as different.
        public static func == (lhs: Version, rhs: Version) -> Bool {
            !(lhs < rhs) && !(rhs < lhs)
        }
    }

    // MARK: - Manifest

    /// A parsed GitHub release. `downloadURL` is nil when no `MacTidy.app.zip`
    /// asset is attached — callers fall back to opening the release page.
    public struct ReleaseManifest: Sendable, Equatable {
        public let version: Version
        public let releaseName: String
        public let notes: String
        public let htmlURL: URL
        public let downloadURL: URL?
        public let downloadSize: Int64

        public init(version: Version, releaseName: String, notes: String,
                    htmlURL: URL, downloadURL: URL?, downloadSize: Int64) {
            self.version = version
            self.releaseName = releaseName
            self.notes = notes
            self.htmlURL = htmlURL
            self.downloadURL = downloadURL
            self.downloadSize = downloadSize
        }
    }

    /// Parses the JSON body of `GET /repos/.../releases/latest`. Returns nil
    /// on malformed JSON or a missing `tag_name`. Pure — no network.
    public static func parseRelease(json: String) -> ReleaseManifest? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String
        else { return nil }

        let name = (obj["name"] as? String) ?? tag
        let body = (obj["body"] as? String) ?? ""
        let htmlString = (obj["html_url"] as? String)
            ?? "https://github.com/\(repoOwner)/\(repoName)/releases/latest"
        guard let htmlURL = URL(string: htmlString) else { return nil }

        var downloadURL: URL?
        var downloadSize: Int64 = 0
        if let assets = obj["assets"] as? [[String: Any]] {
            for asset in assets {
                let assetName = (asset["name"] as? String) ?? ""
                if assetName == UpdateChecker.assetName,
                   let urlStr = asset["browser_download_url"] as? String,
                   let url = URL(string: urlStr) {
                    downloadURL = url
                    downloadSize = Int64((asset["size"] as? Int) ?? 0)
                    break
                }
            }
        }

        return ReleaseManifest(
            version: Version(tag),
            releaseName: name,
            notes: body,
            htmlURL: htmlURL,
            downloadURL: downloadURL,
            downloadSize: downloadSize
        )
    }

    /// True when the manifest's version is strictly newer than the running
    /// app's version string (e.g. `CFBundleShortVersionString`).
    public static func isUpdateAvailable(manifest: ReleaseManifest, current: String) -> Bool {
        manifest.version > Version(current)
    }
}
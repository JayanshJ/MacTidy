import Foundation
import Testing
@testable import CoreKit

/// Privacy contract: the sanitizer must NOT emit file paths/names by default,
/// and must only when `sendFilePaths` is explicitly on. This is the boundary
/// between MacTidy and a cloud model — a regression here leaks user data.
@Suite("ScanSanitizer privacy")
struct ScanSanitizerTests {
    private func sampleResults() -> [CategoryResult] {
        [CategoryResult(
            category: .userCaches,
            items: [ScanItem(url: URL(fileURLWithPath: "/Users/me/Library/Caches/com.example.app/Cache.db"),
                             sizeBytes: 4096, isDirectory: false,
                             detail: "in com.example.app", lastModified: Date())]
        )]
    }

    @Test func pathsAreStrippedByDefault() throws {
        let json = try ScanSanitizer.payload(sampleResults(), sendFilePaths: false)
        // The bundle-id-ish path segment must NOT appear when paths are off.
        #expect(!json.contains("com.example.app"))
        // But the category label and byte size are present (that's the point).
        #expect(json.contains("User caches"))
        #expect(json.contains("4096"))
    }

    @Test func pathsIncludedWhenOptedIn() throws {
        let json = try ScanSanitizer.payload(sampleResults(), sendFilePaths: true)
        #expect(json.contains("Cache.db"))
        #expect(json.contains("in com.example.app"))   // detail also gated
    }

    @Test func resolveOnlyReturnsRealScanItems() {
        let results = sampleResults()
        // A valid category name + valid index resolves to the real item.
        let valid = ScanSanitizer.resolve(
            selection: [("User caches", [0])], in: results)
        #expect(valid.count == 1)

        // A hallucinated category name yields nothing — the model can't
        // select a path that wasn't surfaced by the read-only scanner.
        let bogus = ScanSanitizer.resolve(
            selection: [("Nonexistent", [0])], in: results)
        #expect(bogus.isEmpty)

        // An out-of-range index yields nothing.
        let oob = ScanSanitizer.resolve(
            selection: [("User caches", [99])], in: results)
        #expect(oob.isEmpty)
    }
}
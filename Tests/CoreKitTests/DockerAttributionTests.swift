import Foundation
import Testing
@testable import CoreKit

/// `DockerScanner.parseAttributions` — the heuristic that gives plain
/// `docker run` images a "likely <project>" guess instead of leaving them
/// looking orphaned. Read-only inference from container working dir / bind
/// mounts; only images a container references get an entry.
@Suite("Docker non-compose attribution")
struct DockerAttributionTests {
    // Three standalone images: my-api (running container, bind mount),
    // redis (stopped container, working dir only), and a dangling image no
    // container references.
    static let imagesFixture = """
my-api\tlatest\tsha256:img-api\t540MB\t2 weeks ago
redis\t7\tsha256:img-redis\t130MB\t1 month ago
<none>\t<none>\tsha256:img-dangling\t800MB\t3 days ago
"""

    static let containersFixture = """
c1\tapi-run\tmy-api:latest\tUp 3 hours
c2\tcache\tredis:7\tExited (0) 2 days ago
"""

    /// Inspect string `workingDir|bindSrc1,bindSrc2,` keyed by container id,
    /// returned as the closure `parseAttributions` expects.
    static func inspectFixture() -> (String) -> String {
        let map: [String: String] = [
            "c1": "/Users/jayansh/Projects/my-api|/Users/jayansh/Projects/my-api/src,",
            "c2": "/app|,",
        ]
        return { id in map[id] ?? "" }
    }

    @Test func attributesImageFromBindMountAndMarksInUse() {
        let images = DockerScanner.parseImages(Self.imagesFixture, inspect: { _ in "" })
        let containers = DockerScanner.parseContainers(Self.containersFixture)
        let attrs = DockerScanner.parseAttributions(images: images, containers: containers,
                                                    containerInspect: { Self.inspectFixture()($0) })

        let api = attrs["sha256:img-api"]
        #expect(api != nil)
        // Bind mount source resolves to the "my-api" dir name.
        #expect(api?.projectGuess == "my-api")
        // c1 is running → in use.
        #expect(api?.inUse == true)
    }

    @Test func attributesFromWorkingDirWhenNoBindMount() {
        let images = DockerScanner.parseImages(Self.imagesFixture, inspect: { _ in "" })
        let containers = DockerScanner.parseContainers(Self.containersFixture)
        // Override redis container's inspect so the only signal is a
        // meaningful working dir (no bind mount).
        let map: [String: String] = [
            "c1": "/Users/jayansh/Projects/my-api|/Users/jayansh/Projects/my-api/src,",
            "c2": "/Users/jayansh/Projects/cache-svc|,",
        ]
        let inspect: (String) -> String = { map[$0] ?? "" }
        let attrs = DockerScanner.parseAttributions(images: images, containers: containers,
                                                    containerInspect: inspect)

        let redis = attrs["sha256:img-redis"]
        #expect(redis != nil)
        #expect(redis?.projectGuess == "cache-svc")
        // c2 is Exited → not in use, but still attributed.
        #expect(redis?.inUse == false)
    }

    @Test func rejectsTrivialWorkingDirsAndFallsBackToName() {
        let images = DockerScanner.parseImages(Self.imagesFixture, inspect: { _ in "" })
        let containers = DockerScanner.parseContainers(Self.containersFixture)
        // Trivial working dir (/app) + no bind mount → fall back to container
        // name (stripped of any replica suffix).
        let map: [String: String] = [
            "c1": "/Users/jayansh/Projects/my-api|/Users/jayansh/Projects/my-api/src,",
            "c2": "/app|,",
        ]
        let inspect: (String) -> String = { map[$0] ?? "" }
        let attrs = DockerScanner.parseAttributions(images: images, containers: containers,
                                                    containerInspect: inspect)

        let redis = attrs["sha256:img-redis"]
        #expect(redis?.projectGuess == "cache")
        #expect(redis?.inUse == false)
    }

    @Test func containerLessImageGetsNoAttribution() {
        let images = DockerScanner.parseImages(Self.imagesFixture, inspect: { _ in "" })
        let containers = DockerScanner.parseContainers(Self.containersFixture)
        let attrs = DockerScanner.parseAttributions(images: images, containers: containers,
                                                    containerInspect: { Self.inspectFixture()($0) })

        // The dangling image has no container → no entry → the UI treats it
        // as orphaned. This is the honest "safe to prune" case.
        #expect(attrs["sha256:img-dangling"] == nil)
        #expect(attrs.count == 2)
    }

    @Test func composeImagesAreNotAttributed() {
        // A compose-labeled image is already attributed by the project
        // grouping; parseAttributions must skip it even if a container refs it.
        let images = DockerScanner.parseImages(Self.imagesFixture) { id in
            id.contains("img-api") ? "myapp" : ""
        }
        let containers = DockerScanner.parseContainers(Self.containersFixture)
        let attrs = DockerScanner.parseAttributions(images: images, containers: containers,
                                                    containerInspect: { Self.inspectFixture()($0) })
        #expect(attrs["sha256:img-api"] == nil)
    }
}
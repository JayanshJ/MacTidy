import Foundation
import Testing
@testable import CoreKit

@Suite("DockerScanner parsing")
struct DockerScannerTests {
    /// Tab-separated `docker images` rows, matching the --format template in
    /// DockerScanner.parseImages.
    static let imagesFixture = """
<none>\t<none>\tsha256:abc123\t100MB\t2 days ago
postgres\t15\tsha256:def456\t400MB\t5 days ago
nginx\tlatest\tsha256:ghi789\t50MB\t1 day ago
"""

    static let containersFixture = """
sha256:c1\tmyapp-web-1\tpostgres:15\tUp 2 hours
sha256:c2\tmyapp-db-1\tpostgres:15\tExited (0) 4 hours ago
"""

    /// Two images, one labeled with a compose project, one not.
    static func inspectFixture(for project: String?) -> String {
        project ?? ""
    }

    @Test func parsesImagesAndFlagsDangling() {
        let images = DockerScanner.parseImages(Self.imagesFixture, inspect: { _ in "" })
        #expect(images.count == 3)
        let dangling = images.first { $0.dangling }
        #expect(dangling?.repository == "<none>")
        #expect(dangling?.tag == "<none>")
        #expect(dangling?.sizeBytes == 100_000_000)
        let pg = images.first { $0.repository == "postgres" }
        #expect(pg?.tag == "15")
        #expect(pg?.sizeBytes == 400_000_000)
    }

    @Test func parsesContainersAndRunningState() {
        let containers = DockerScanner.parseContainers(Self.containersFixture)
        #expect(containers.count == 2)
        let web = containers.first { $0.name == "myapp-web-1" }
        #expect(web?.running == true)
        let db = containers.first { $0.name == "myapp-db-1" }
        #expect(db?.running == false)
        #expect(db?.image == "postgres:15")
    }

    @Test func attributesImagesToComposeProjectViaLabel() {
        // postgres image is labeled "myapp"; others have no label.
        let images = DockerScanner.parseImages(Self.imagesFixture) { id in
            id.contains("def456") ? "myapp" : ""
        }
        let pg = images.first { $0.repository == "postgres" }
        #expect(pg?.composeProject == "myapp")
        let nginx = images.first { $0.repository == "nginx" }
        #expect(nginx?.composeProject == nil)
    }

    @Test func groupsProjectsAndComputesStandalone() {
        let images = DockerScanner.parseImages(Self.imagesFixture) { id in
            id.contains("def456") ? "myapp" : ""
        }
        let containers = DockerScanner.parseContainers(Self.containersFixture)
        let state = DockerState(images: images, containers: containers)
        #expect(state.projects.count == 1)
        let project = state.projects.first
        #expect(project?.name == "myapp")
        #expect(project?.images.count == 1)
        #expect(project?.totalBytes == 400_000_000)
        // db container runs a postgres image belonging to myapp → project running.
        #expect(project?.running == true)
        // nginx + dangling are standalone.
        #expect(state.standaloneImages.count == 2)
    }

    @Test func emptyFixturesYieldEmptyState() {
        let images = DockerScanner.parseImages("", inspect: { _ in "" })
        let containers = DockerScanner.parseContainers("")
        #expect(images.isEmpty)
        #expect(containers.isEmpty)
    }
}
import Foundation
import Testing
@testable import CoreKit

@Suite("DockerActions command summary")
struct DockerActionsTests {
    private func image(id: String, repo: String, tag: String, bytes: Int64) -> DockerImage {
        DockerImage(id: id, repository: repo, tag: tag, sizeBytes: bytes,
                    createdSince: "now", composeProject: nil)
    }

    @Test func imageRemoveCommandAndLabel() {
        let img = image(id: "sha256:abc123", repo: "postgres", tag: "15", bytes: 400_000_000)
        let action = DockerImageRemoveAction(image: img)
        #expect(action.commandSummary == "docker rmi -f sha256:abc123")
        #expect(action.reversible == false)
        #expect(action.estimatedBytes == 400_000_000)
        #expect(action.displayName == "postgres:15")
    }

    @Test func danglingImageDisplayName() {
        let img = image(id: "sha256:abc", repo: "<none>", tag: "<none>", bytes: 10)
        let action = DockerImageRemoveAction(image: img)
        #expect(action.displayName == "dangling image sha256:abc")
    }

    @Test func composeDownDefaultsToNoVolumes() {
        let project = DockerComposeProject(name: "myapp", images: [
            image(id: "sha256:1", repo: "web", tag: "latest", bytes: 100)
        ], running: true)
        let action = DockerComposeDownAction(project: project, removeVolumes: false)
        // compose down + explicit rmi per image (in case containers are gone).
        #expect(action.commandSummary == "docker compose -p myapp down --rmi all && docker rmi -f sha256:1")
        #expect(action.estimatedBytes == 100)
        #expect(action.displayName == "Compose project myapp")
    }

    @Test func composeDownWithVolumesAppendsFlag() {
        let project = DockerComposeProject(name: "myapp", images: [], running: false)
        let action = DockerComposeDownAction(project: project, removeVolumes: true)
        // No images → no rmi suffix, just compose down with --volumes.
        #expect(action.commandSummary == "docker compose -p myapp down --rmi all --volumes")
    }

    @Test func composeDownWithMultipleImagesRemovesEach() {
        let project = DockerComposeProject(name: "webapp", images: [
            image(id: "sha256:1", repo: "web", tag: "latest", bytes: 100),
            image(id: "sha256:2", repo: "db", tag: "15", bytes: 200),
        ], running: false)
        let action = DockerComposeDownAction(project: project, removeVolumes: false)
        #expect(action.commandSummary == "docker compose -p webapp down --rmi all && docker rmi -f sha256:1 && docker rmi -f sha256:2")
        #expect(action.estimatedBytes == 300)
    }
}
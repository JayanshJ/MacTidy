# Docker cleanup + node_modules UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Docker cleanup tab (delete whole Compose projects / standalone images / stopped containers) and fix the node_modules cleanup UX (group by project in the main list, always show prune + trash actions).

**Architecture:** A new shell-based destructive path (`ShellAction` protocol + `ShellActionExecutor`) sits alongside the existing filesystem path (`Trasher`), feeding the same `CleanupLog`. Docker is its first user; the filesystem pipeline is untouched. Docker deletion is irreversible (no Trash), so it gets its own confirmation sheet with an explicit no-undo banner, and logs to `CleanupLog` only (not `TrashLog`).

**Tech Stack:** Swift 6, SwiftPM, SwiftUI (macOS 14+), Swift Testing (`import Testing`), Command Line Tools (no Xcode).

**Spec:** `docs/superpowers/specs/2026-08-25-docker-and-nodemodules-design.md`

## Global Constraints

- **Always run tests with `make test`, never `swift test`** — bare CLT needs the global `-F` flag that `make test` injects; `swift test` silently runs 0 tests.
- **Never add the App Sandbox entitlement.** The app is non-sandboxed by design; sandboxing breaks FDA, `trashItem`, `clonefile`, and shell-out.
- **The filesystem destructive path is off-limits.** Do not modify `SafePathPolicy`, `Trasher`, `DeletionExecutor`, or `DeletionPlan`. The new `ShellAction` path is parallel, not integrated into them.
- **No `FileManager.removeItem`, no `rm`.** The only filesystem mutator is `Trasher.trash`. Shell actions mutate via `docker` only, never the host filesystem directly.
- **Docker shell-out uses `Shell.run` / `Shell.find`** (same helper `DockerInfo` and `NodePackagesInspector` already use at `Sources/CoreKit/Support/Shell.swift`). Do not consult `$PATH`.
- **Shell actions are per-item fail-closed.** One failed `docker rmi` skips only itself; it must never abort the batch (mirror `DeletionExecutor`).
- **Docker actions are irreversible (`reversible: false`).** No `TrashLog`/`Restorer` entries. Log reclaimed bytes to `CleanupLog` with `kind: .docker` on real passes only.
- **Tests are Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest. Test files live in `Tests/CoreKitTests/` and `@testable import CoreKit`.
- **Reclaim bytes are estimates.** `docker images` size is shared-layer size; sums over-count. UI shows "≈" and `CleanupLog` records the estimate. Do not chase exact freed-byte reconciliation.

---

## File Structure

**Create:**
- `Sources/CoreKit/Safety/ShellAction.swift` — `ShellAction` protocol, `ShellActionOutcome`, `ShellActionExecutor`. One responsibility: run a batch of shell commands per-item fail-closed, dry-run aware.
- `Sources/CoreKit/Scanning/DockerScanner.swift` — `DockerImage`, `DockerContainer`, `DockerComposeProject`, `DockerState`, `DockerScanner`. One responsibility: parse `docker` CLI output into structured models.
- `Sources/CoreKit/Safety/DockerActions.swift` — `DockerImageRemoveAction`, `DockerComposeDownAction`, `DockerContainerRemoveAction`. One responsibility: concrete `ShellAction`s for Docker.
- `Sources/MacTidyApp/Views/DockerTab.swift` — `DashboardDocker` view + `DockerActionConfirmationSheet`. One responsibility: Docker tab UI.
- `Tests/CoreKitTests/ShellActionExecutorTests.swift`
- `Tests/CoreKitTests/DockerScannerTests.swift`
- `Tests/CoreKitTests/DockerActionsTests.swift`

**Modify:**
- `Sources/CoreKit/Safety/CleanupLog.swift:8` — add `.docker` to `CleanupEntry.Kind`.
- `Sources/MacTidyApp/AppState.swift` — add `executeShellActions(_:kind:)` + private recorder.
- `Sources/MacTidyApp/Views/DashboardView.swift` — add `.docker` tab; group node_modules by project; add "Analyze packages" button.
- `Sources/MacTidyApp/Views/DashboardTabs.swift:410-554` — `NodePackagesInspector`: always show prune + trash buttons.

---

## Task 1: ShellAction protocol + executor

**Files:**
- Create: `Sources/CoreKit/Safety/ShellAction.swift`
- Test: `Tests/CoreKitTests/ShellActionExecutorTests.swift`

**Interfaces:**
- Consumes: `Shell.run(_:_:)` from `Sources/CoreKit/Support/Shell.swift:15` (returns `Shell.Output?`, `succeeded` when `exitCode == 0`).
- Produces:
  - `protocol ShellAction: Identifiable, Sendable` with `id: UUID`, `displayName: String`, `commandSummary: String`, `reversible: Bool`, `estimatedBytes: Int64`
  - `struct ShellActionOutcome: Sendable` with `succeeded: [any ShellAction]`, `failed: [Failure]`, `dryRun: Bool`, `reclaimedBytes: Int64`
  - `struct ShellActionOutcome.Failure: Identifiable, Sendable` with `id: UUID`, `action: any ShellAction`, `message: String`
  - `enum ShellActionExecutor` with `static func execute(_ actions: [any ShellAction], dryRun: Bool) -> ShellActionOutcome`

- [ ] **Step 1: Write the failing test**

Create `Tests/CoreKitTests/ShellActionExecutorTests.swift`:

```swift
import Foundation
import Testing
@testable import CoreKit

@Suite("ShellActionExecutor")
struct ShellActionExecutorTests {
    /// A test action wrapping an arbitrary command. `shouldFail` makes it run
    /// `/bin/false` so exitCode != 0.
    struct TestAction: ShellAction {
        let id = UUID()
        let displayName: String
        let commandSummary: String
        let reversible = false
        let estimatedBytes: Int64
        let shouldFail: Bool
        var commandPath: String { shouldFail ? "/bin/false" : "/bin/true" }
    }

    @Test func dryRunReportsAllAsSucceededWithoutExecuting() {
        let action = TestAction(displayName: "t", commandSummary: "docker rmi abc",
                                estimatedBytes: 500, shouldFail: true)
        let outcome = ShellActionExecutor.execute([action], dryRun: true)
        #expect(outcome.dryRun)
        #expect(outcome.succeeded.count == 1)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.reclaimedBytes == 500)
    }

    @Test func successfulActionSucceedsAndCountsBytes() {
        let action = TestAction(displayName: "t", commandSummary: "docker rmi abc",
                                estimatedBytes: 500, shouldFail: false)
        let outcome = ShellActionExecutor.execute([action], dryRun: false)
        #expect(!outcome.dryRun)
        #expect(outcome.succeeded.count == 1)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.reclaimedBytes == 500)
    }

    @Test func failingActionDoesNotAbortTheRest() {
        let good = TestAction(displayName: "good", commandSummary: "docker rmi good",
                              estimatedBytes: 300, shouldFail: false)
        let bad = TestAction(displayName: "bad", commandSummary: "docker rmi bad",
                             estimatedBytes: 700, shouldFail: true)
        let outcome = ShellActionExecutor.execute([bad, good], dryRun: false)
        #expect(outcome.succeeded.count == 1)
        #expect(outcome.succeeded.first?.displayName == "good")
        #expect(outcome.failed.count == 1)
        #expect(outcome.failed.first?.action.displayName == "bad")
        // Reclaimed bytes only counts succeeded actions.
        #expect(outcome.reclaimedBytes == 300)
        // Failure carries a non-empty message (stderr or fallback).
        #expect(!outcome.failed.first?.message.isEmpty ?? false)
    }

    @Test func emptyBatchIsHarmless() {
        let outcome = ShellActionExecutor.execute([], dryRun: false)
        #expect(outcome.succeeded.isEmpty)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.reclaimedBytes == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep -A3 ShellActionExecutor || true`
Expected: compile error — `ShellAction` / `ShellActionExecutor` not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoreKit/Safety/ShellAction.swift`:

```swift
import Foundation

/// A destructive action executed by shelling out to an external tool (docker,
/// brew, …) rather than mutating the filesystem via `Trasher`. Unlike trashed
/// files, shell actions are generally **not** Trash-undoable — the confirmation
/// sheet makes that explicit. This path is parallel to, and deliberately
/// separate from, the filesystem pipeline (`SafePathPolicy` + `Trasher`).
public protocol ShellAction: Identifiable, Sendable {
    var id: UUID { get }
    /// Human label for the confirmation sheet, e.g. "Image postgres:15".
    var displayName: String { get }
    /// The literal command that will run, shown verbatim in the confirmation
    /// sheet so the user sees exactly what MacTidy will execute.
    var commandSummary: String { get }
    /// `false` for actions with no Trash-based undo (all Docker actions).
    var reversible: Bool { get }
    /// Estimated bytes this action reclaims, for the confirmation total and
    /// the reclaim-over-time log. An estimate — shared layers over-count.
    var estimatedBytes: Int64 { get }
    /// Runs the real command. Returns nil on failure to even launch; a
    /// non-nil Output with non-zero exitCode is a per-item failure.
    func run() -> Shell.Output?
}

public extension ShellAction {
    /// Default executor: split command into argv via the action's own
    /// `commandSummary`-independent path. Concrete actions override `run()`
    /// directly, so this is unused but keeps the protocol concrete-friendly.
}

/// Outcome of executing a batch of `ShellAction`s. Per-item fail-closed: a
/// failed action is reported in `failed` and does not abort the rest.
public struct ShellActionOutcome: Sendable {
    public struct Failure: Identifiable, Sendable {
        public let id: UUID
        public let action: any ShellAction
        public let message: String
        public init(action: any ShellAction, message: String) {
            self.id = UUID()
            self.action = action
            self.message = message
        }
    }
    public var succeeded: [any ShellAction]
    public var failed: [Failure]
    public var dryRun: Bool

    public init(succeeded: [any ShellAction] = [], failed: [Failure] = [], dryRun: Bool) {
        self.succeeded = succeeded
        self.failed = failed
        self.dryRun = dryRun
    }

    public var reclaimedBytes: Int64 {
        succeeded.reduce(0) { $0 + $1.estimatedBytes }
    }
}

public enum ShellActionExecutor {
    /// Executes `actions` per-item. In `dryRun`, nothing runs — every action is
    /// reported as would-run (`succeeded`, with the dry-run flag set so the UI
    /// can show "would have run"). Otherwise each action runs; success adds to
    /// `succeeded`, failure (nil Output or non-zero exit) adds to `failed`
    /// with the real stderr. A failure never aborts the remaining actions.
    public static func execute(_ actions: [any ShellAction], dryRun: Bool) -> ShellActionOutcome {
        if dryRun {
            return ShellActionOutcome(succeeded: actions, failed: [], dryRun: true)
        }
        var succeeded: [any ShellAction] = []
        var failed: [ShellActionOutcome.Failure] = []
        for action in actions {
            guard let output = action.run() else {
                failed.append(.init(action: action, message: "Failed to launch command."))
                continue
            }
            if output.succeeded {
                succeeded.append(action)
            } else {
                let msg = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                failed.append(.init(action: action, message: msg.isEmpty ? "Command exited with code \(output.exitCode)." : msg))
            }
        }
        return ShellActionOutcome(succeeded: succeeded, failed: failed, dryRun: false)
    }
}
```

Note: the test's `TestAction` conforms to `ShellAction` and implements `run()` itself (returning `Shell.run(commandPath, [])`). Update the protocol so `run()` is a required method — the `public extension ShellAction` stub above is empty/wrong; **remove that extension** and instead the protocol must declare `run() -> Shell.Output?`. Fix: replace the empty `public extension ShellAction { ... }` block (lines ~16-19) — it should not exist. The protocol must include:

```swift
    /// Runs the real command. Returns nil only if the process could not be
    /// launched; a non-nil Output with a non-zero exitCode is a per-item failure.
    func run() -> Shell.Output?
```

as a required member of `protocol ShellAction`. Then the test's `TestAction` provides:

```swift
    func run() -> Shell.Output? { Shell.run(commandPath, []) }
```

Apply this correction when writing the file: the protocol has 6 required members — `id`, `displayName`, `commandSummary`, `reversible`, `estimatedBytes`, `run()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `make test 2>&1 | grep -A3 ShellActionExecutor || true`
Expected: PASS — all 4 tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoreKit/Safety/ShellAction.swift Tests/CoreKitTests/ShellActionExecutorTests.swift
git commit -m "Add ShellAction executor for shell-based destructive actions

Parallel to Trasher; per-item fail-closed; dry-run aware. Docker is the
first user."
```

---

## Task 2: CleanupEntry.Kind.docker

**Files:**
- Modify: `Sources/CoreKit/Safety/CleanupLog.swift:8-12`
- Test: `Tests/CoreKitTests/CleanupLogTests.swift` (add a case)

**Interfaces:**
- Consumes: existing `CleanupEntry.Kind`.
- Produces: `CleanupEntry.Kind.docker` — used by Task 5's `AppState` recorder.

- [ ] **Step 1: Write the failing test**

Append to `Tests/CoreKitTests/CleanupLogTests.swift` (inside the existing `@Suite` or a new one):

```swift
    @Test func dockerKindRoundTripsThroughCodable() throws {
        let entry = CleanupEntry(kind: .docker, reclaimedBytes: 1_000_000, itemCount: 3)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(CleanupEntry.self, from: data)
        #expect(decoded.kind == .docker)
        #expect(decoded.reclaimedBytes == 1_000_000)
        #expect(decoded.itemCount == 3)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep -A3 dockerKind || true`
Expected: compile error — `.docker` not a case of `CleanupEntry.Kind`.

- [ ] **Step 3: Write the implementation**

In `Sources/CoreKit/Safety/CleanupLog.swift`, change the `Kind` enum:

```swift
    public enum Kind: String, Sendable, Codable {
        case deletion
        case dedup
        case uninstall
        case docker
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test 2>&1 | grep -A3 dockerKind || true`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoreKit/Safety/CleanupLog.swift Tests/CoreKitTests/CleanupLogTests.swift
git commit -m "Add CleanupEntry.Kind.docker"
```

---

## Task 3: DockerScanner — parse docker CLI into structured models

**Files:**
- Create: `Sources/CoreKit/Scanning/DockerScanner.swift`
- Test: `Tests/CoreKitTests/DockerScannerTests.swift`

**Interfaces:**
- Consumes: `Shell.find(_:)` and `Shell.run(_:_:)` from `Sources/CoreKit/Support/Shell.swift`.
- Produces:
  - `struct DockerImage: Identifiable, Sendable, Hashable` — `id`, `repository`, `tag`, `sizeBytes`, `createdSince`, `composeProject: String?`, computed `dangling: Bool`
  - `struct DockerContainer: Identifiable, Sendable, Hashable` — `id`, `name`, `image`, `running: Bool`
  - `struct DockerComposeProject: Identifiable, Sendable, Hashable` — `name`, `images: [DockerImage]`, computed `totalBytes: Int64`, `running: Bool`
  - `struct DockerState: Sendable` — `images`, `containers`, `projects`, computed `standaloneImages: [DockerImage]`
  - `enum DockerScanner` with `static func availability() -> Availability`, `static func scan() -> DockerState?`, `static func systemDFTable() -> String?`
  - `enum DockerScanner.Availability: Sendable` — `.available`, `.notInstalled`, `.notRunning`

- [ ] **Step 1: Write the failing test**

Create `Tests/CoreKitTests/DockerScannerTests.swift`. Tests use pure parser functions over inlined stdout fixtures (no real Docker):

```swift
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
sha256:c1\tmyapp-web-1\tmyapp_web:latest\tUp 2 hours
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep -A3 DockerScanner || true`
Expected: compile error — `DockerScanner` / model types not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoreKit/Scanning/DockerScanner.swift`:

```swift
import Foundation

/// Structured Docker state for the Docker cleanup tab. Distinct from
/// `DockerInfo`, which only exposes the raw `docker system df` table — this
/// parses images/containers into models the UI can group and act on.
public struct DockerImage: Identifiable, Sendable, Hashable {
    public let id: String
    public let repository: String
    public let tag: String
    public let sizeBytes: Int64
    public let createdSince: String
    public let composeProject: String?
    public var dangling: Bool { repository == "<none>" && tag == "<none>" }

    public init(id: String, repository: String, tag: String,
                sizeBytes: Int64, createdSince: String, composeProject: String?) {
        self.id = id
        self.repository = repository
        self.tag = tag
        self.sizeBytes = sizeBytes
        self.createdSince = createdSince
        self.composeProject = composeProject
    }
}

public struct DockerContainer: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let image: String
    public let running: Bool

    public init(id: String, name: String, image: String, running: Bool) {
        self.id = id
        self.name = name
        self.image = image
        self.running = running
    }
}

public struct DockerComposeProject: Identifiable, Sendable, Hashable {
    public let name: String
    public let images: [DockerImage]
    public let running: Bool
    public var id: String { name }
    public var totalBytes: Int64 { images.reduce(0) { $0 + $1.sizeBytes } }

    public init(name: String, images: [DockerImage], running: Bool) {
        self.name = name
        self.images = images
        self.running = running
    }
}

public struct DockerState: Sendable {
    public let images: [DockerImage]
    public let containers: [DockerContainer]
    public let projects: [DockerComposeProject]

    public init(images: [DockerImage], containers: [DockerContainer]) {
        self.images = images
        self.containers = containers
        // Group images by compose project label, ignoring nil/empty.
        let grouped = Dictionary(grouping: images.filter { !($0.composeProject?.isEmpty ?? true) },
                                 by: { $0.composeProject! })
        self.projects = grouped.map { name, imgs in
            // A project is running if any container's image repo:tag matches
            // one of the project's images, and that container is up.
            let running = containers.contains { c in
                c.running && imgs.contains { img in
                    c.image == "\(img.repository):\(img.tag)" || c.image.contains(img.id)
                }
            }
            return DockerComposeProject(name: name, images: imgs, running: running)
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    public var standaloneImages: [DockerImage] {
        images.filter { $0.composeProject?.isEmpty ?? true }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }
}

public enum DockerScanner {
    public enum Availability: Sendable { case available, notInstalled, notRunning }

    /// Looks up the docker binary in standard locations only (no $PATH).
    public static func availability() -> Availability {
        guard let docker = Shell.find("docker") else { return .notInstalled }
        guard let out = Shell.run(docker, ["info", "--format", "{{.ServerVersion}}"]),
              out.succeeded else { return .notRunning }
        return .available
    }

    /// Full structured scan. Returns nil when docker is unavailable.
    public static func scan() -> DockerState? {
        guard let docker = Shell.find("docker") else { return nil }
        guard let imagesRaw = Shell.run(docker, ["images", "--no-trunc", "--format",
                "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}"]),
              imagesRaw.succeeded else { return nil }
        let containersRaw = Shell.run(docker, ["ps", "-a", "--format",
                "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"])
        let images = parseImages(imagesRaw.stdout) { id in
            guard let inspect = Shell.run(docker, ["image", "inspect", id, "--format",
                    "{{ index .Config.Labels \"com.docker.compose.project\" }}"]),
                  inspect.succeeded else { return "" }
            return inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let containers = parseContainers(containersRaw?.stdout ?? "")
        return DockerState(images: images, containers: containers)
    }

    /// Raw `docker system df` table for the secondary detail view. Delegates
    /// to the existing DockerInfo usage() but returns the string directly.
    public static func systemDFTable() -> String? { DockerInfo.usage()?.table }

    // MARK: - Parsers (pure, testable without docker)

    /// Parses `docker images --format` tab-separated rows. `inspect` returns the
    /// compose-project label for a given image ID (empty string when none).
    public static func parseImages(_ raw: String, inspect: (String) -> String) -> [DockerImage] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 5 else { return nil }
            let id = cols[2]
            // docker prints IDs as "sha256:..."; strip the prefix for display but keep full.
            let project = inspect(id)
            return DockerImage(
                id: id,
                repository: cols[0],
                tag: cols[1],
                sizeBytes: parseSize(cols[3]),
                createdSince: cols[4],
                composeProject: project.isEmpty ? nil : project
            )
        }
    }

    /// Parses `docker ps -a --format` tab-separated rows. Status starting
    /// with "Up" → running.
    public static func parseContainers(_ raw: String) -> [DockerContainer] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 4 else { return nil }
            return DockerContainer(
                id: cols[0],
                name: cols[1],
                image: cols[2],
                running: cols[3].hasPrefix("Up")
            )
        }
    }

    /// Parses a human docker size ("100MB", "1.2GB", "5.43kB") to bytes.
    static func parseSize(_ s: String) -> Int64 {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract numeric prefix and unit suffix.
        var numStr = ""
        var unit = ""
        for ch in trimmed {
            if ch.isNumber || ch == "." { numStr.append(ch) }
            else { unit.append(ch) }
        }
        guard let value = Double(numStr) else { return 0 }
        let multipliers: [String: Double] = [
            "B": 1, "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000,
            "TB": 1_000_000_000_000, "B": 1
        ]
        // Normalize: docker uses "MB"/"GB"; handle lowercase + missing B.
        let key = unit.uppercased()
        let mult = multipliers[key] ?? multipliers[key.replacingOccurrences(of: "B", with: "")].map { $0 * 1 } ?? 1
        return Int64(value * mult)
    }
}
```

Note on `parseSize`: docker's `--format {{.Size}}` emits values like "100MB", "1.2GB", "5.43kB". The multiplier lookup must handle `kB`/`KB`. Simplify the last lines to:

```swift
        let key = unit.uppercased()
        let mult: Double
        switch key {
        case "B", "": mult = 1
        case "KB", "K": mult = 1_000
        case "MB", "M": mult = 1_000_000
        case "GB", "G": mult = 1_000_000_000
        case "TB", "T": mult = 1_000_000_000_000
        default: mult = 1
        }
        return Int64(value * mult)
```

Apply that simpler switch when writing the file (remove the buggy `multipliers` dictionary version above).

- [ ] **Step 4: Run test to verify it passes**

Run: `make test 2>&1 | grep -A3 DockerScanner || true`
Expected: PASS — all 5 tests green. If the `running` assertion fails, verify the container/image match logic in `DockerState.init` matches `postgres:15` against the `myapp-db-1` container (image `"postgres:15"`, image repo `"postgres"` tag `"15"` → `"postgres:15"` matches).

- [ ] **Step 5: Commit**

```bash
git add Sources/CoreKit/Scanning/DockerScanner.swift Tests/CoreKitTests/DockerScannerTests.swift
git commit -m "Add DockerScanner: parse docker CLI into structured models"
```

---

## Task 4: Docker shell actions

**Files:**
- Create: `Sources/CoreKit/Safety/DockerActions.swift`
- Test: `Tests/CoreKitTests/DockerActionsTests.swift`

**Interfaces:**
- Consumes: `ShellAction` (Task 1), `DockerImage`/`DockerContainer`/`DockerComposeProject` (Task 3), `Shell.run` / `Shell.find`.
- Produces: `DockerImageRemoveAction`, `DockerComposeDownAction`, `DockerContainerRemoveAction` — all `ShellAction` conformers used by the UI in Task 6.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoreKitTests/DockerActionsTests.swift`:

```swift
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
        #expect(action.commandSummary == "docker compose -p myapp down --rmi all")
        #expect(action.estimatedBytes == 100)
        #expect(action.displayName == "Compose project myapp")
    }

    @Test func composeDownWithVolumesAppendsFlag() {
        let project = DockerComposeProject(name: "myapp", images: [], running: false)
        let action = DockerComposeDownAction(project: project, removeVolumes: true)
        #expect(action.commandSummary == "docker compose -p myapp down --rmi all --volumes")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep -A3 DockerActions || true`
Expected: compile error — action types not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoreKit/Safety/DockerActions.swift`:

```swift
import Foundation

/// Removes one Docker image by ID. `docker rmi -f` forces removal even when the
/// image has tagged children. Irreversible — no Trash.
public struct DockerImageRemoveAction: ShellAction {
    public let id = UUID()
    public let image: DockerImage
    public var displayName: String {
        image.dangling ? "dangling image \(image.id)" : "\(image.repository):\(image.tag)"
    }
    public var commandSummary: String { "docker rmi -f \(image.id)" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { image.sizeBytes }

    public init(image: DockerImage) { self.image = image }

    public func run() -> Shell.Output? {
        guard let docker = Shell.find("docker") else { return nil }
        return Shell.run(docker, ["rmi", "-f", image.id])
    }
}

/// Tears down a whole Compose project: stops its containers and removes its
/// images (`--rmi all`). Volumes are preserved by default; pass
/// `removeVolumes: true` to also remove named volumes (destructive for DBs).
public struct DockerComposeDownAction: ShellAction {
    public let id = UUID()
    public let project: DockerComposeProject
    public let removeVolumes: Bool
    public var displayName: String { "Compose project \(project.name)" }
    public var commandSummary: String {
        var cmd = "docker compose -p \(project.name) down --rmi all"
        if removeVolumes { cmd += " --volumes" }
        return cmd
    }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { project.totalBytes }

    public init(project: DockerComposeProject, removeVolumes: Bool = false) {
        self.project = project
        self.removeVolumes = removeVolumes
    }

    public func run() -> Shell.Output? {
        guard let docker = Shell.find("docker") else { return nil }
        var args = ["compose", "-p", project.name, "down", "--rmi", "all"]
        if removeVolumes { args.append("--volumes") }
        return Shell.run(docker, args)
    }
}

/// Removes a stopped container by ID. `docker rm` refuses running containers
/// (the UI only offers this for stopped ones). Reclaims ~0 disk.
public struct DockerContainerRemoveAction: ShellAction {
    public let id = UUID()
    public let container: DockerContainer
    public var displayName: String { "stopped container \(container.name)" }
    public var commandSummary: String { "docker rm \(container.id)" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init(container: DockerContainer) { self.container = container }

    public func run() -> Shell.Output? {
        guard let docker = Shell.find("docker") else { return nil }
        return Shell.run(docker, ["rm", container.id])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test 2>&1 | grep -A3 DockerActions || true`
Expected: PASS — all 4 tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoreKit/Safety/DockerActions.swift Tests/CoreKitTests/DockerActionsTests.swift
git commit -m "Add Docker shell actions (image/compose/container removal)"
```

---

## Task 5: AppState.executeShellActions

**Files:**
- Modify: `Sources/MacTidyApp/AppState.swift` (add method + recorder, near the existing `execute` at line 322 and `recordOutcome` at line 470)

**Interfaces:**
- Consumes: `ShellActionExecutor.execute` (Task 1), `ShellActionOutcome` (Task 1), `CleanupEntry`/`CleanupLog` (existing + Task 2 `.docker`).
- Produces: `AppState.executeShellActions(_:kind:) -> ShellActionOutcome` — called by the Docker UI (Task 6).

This is App-layer (no unit test — UI gateway, like the existing `execute`). Verify by compile + the manual launch in Task 7.

- [ ] **Step 1: Add the method**

In `Sources/MacTidyApp/AppState.swift`, add after the existing `execute(_:extraAllowedRoots:kind:)` (ends line 334):

```swift
    /// Gateway for shell-based destructive actions (Docker, future brew). Like
    /// `execute`, it is non-throwing and per-item fail-closed: failures come
    /// back in the outcome's `failed` list. Unlike trashing, these actions are
    /// NOT Trash-undoable, so they are NOT recorded to `TrashLog` — only the
    /// reclaim-over-time `CleanupLog` gets an entry on real passes.
    @discardableResult
    func executeShellActions(
        _ actions: [any ShellAction],
        kind: CleanupEntry.Kind
    ) -> ShellActionOutcome {
        let outcome = ShellActionExecutor.execute(actions, dryRun: dryRun)
        if !outcome.dryRun, outcome.reclaimedBytes > 0 {
            cleanupLog.append(CleanupEntry(
                kind: kind,
                reclaimedBytes: outcome.reclaimedBytes,
                itemCount: outcome.succeeded.count
            ))
            cleanupHistory = cleanupLog.load()
        }
        return outcome
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `make app 2>&1 | tail -5`
Expected: build succeeds (warnings OK). This is a build check, not a test — the method is exercised in Task 7's manual run.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacTidyApp/AppState.swift
git commit -m "Wire AppState.executeShellActions to CleanupLog"
```

---

## Task 6: Docker tab UI + confirmation sheet

**Files:**
- Create: `Sources/MacTidyApp/Views/DockerTab.swift`
- Modify: `Sources/MacTidyApp/Views/DashboardView.swift:18-36` (add `.docker` to `DashboardTab`), `:103-116` (switch case), `:67-99` (no change needed — tab bar is generic over `allCases`)

**Interfaces:**
- Consumes: `DockerScanner`/`DockerState`/models (Task 3), `DockerImageRemoveAction`/`DockerComposeDownAction`/`DockerContainerRemoveAction` (Task 4), `AppState.executeShellActions` (Task 5), `Theme`/`Card` from `Shared.swift`/`Theme.swift`.
- Produces: `DashboardDocker` view + `DockerActionConfirmationSheet`.

This is UI; verified by `make app` + manual launch (Task 7), not unit tests.

- [ ] **Step 1: Add the `.docker` tab case**

In `Sources/MacTidyApp/Views/DashboardView.swift`, update the `DashboardTab` enum:

```swift
    enum DashboardTab: String, CaseIterable, Identifiable {
        case insights = "Insights"
        case cleanup = "Cleanup"
        case byApp = "Storage by App"
        case uninstaller = "Uninstaller"
        case startup = "Startup"
        case docker = "Docker"
        case duplicates = "Duplicates"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .insights: "sparkles"
            case .cleanup: "square.grid.2x2"
            case .byApp: "person.crop.square"
            case .uninstaller: "trash.slash"
            case .startup: "power"
            case .docker: "cylinder.split.1x2"
            case .duplicates: "doc.on.doc"
            }
        }
    }
```

And in the `content` switch (`:103-116`), add a case:

```swift
        case .docker: DashboardDocker()
```

- [ ] **Step 2: Create the Docker tab view**

Create `Sources/MacTidyApp/Views/DockerTab.swift`:

```swift
import SwiftUI
import CoreKit

/// Docker cleanup tab: shows disk usage, groups images by Compose project, and
/// lets the user remove whole projects, standalone images, or stopped
/// containers. All removals are irreversible (no Trash) and go through the
/// `DockerActionConfirmationSheet`.
struct DashboardDocker: View {
    @Environment(AppState.self) private var state
    @State private var dockerState: DockerState?
    @State private var availability: DockerScanner.Availability?
    @State private var isLoading = false
    @State private var dfTable: String?
    @State private var pendingActions: [any ShellAction] = []
    @State private var showSheet = false
    @State private var removeVolumes = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showSheet) {
            DockerActionConfirmationSheet(
                actions: pendingActions,
                removeVolumes: $removeVolumes,
                onCompleted: { Task { await scan() } }
            )
        }
        .task { if availability == nil { await scan() } }
    }

    private var header: some View {
        HStack {
            Text("Docker").font(.title3.bold())
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button { Task { await scan() } } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && dockerState == nil {
            ProgressView("Scanning Docker…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if availability == .notInstalled {
            ContentUnavailableView("Docker isn't installed",
                systemImage: "cylinder.split.1x2",
                description: Text("Install Docker Desktop to reclaim space from images and containers."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if availability == .notRunning {
            VStack(spacing: Theme.Spacing.md) {
                ContentUnavailableView("Docker is not running",
                    systemImage: "power.circle",
                    description: Text("Start Docker Desktop, then rescan."))
                Button("Open Docker") { openDocker() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let ds = dockerState {
            dockerList(ds)
        } else {
            ContentUnavailableView("No Docker data",
                systemImage: "cylinder.split.1x2",
                description: Text("Docker reports no images or containers."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func dockerList(_ ds: DockerState) -> some View {
        List {
            if let df = dfTable, !df.isEmpty {
                DisclosureGroup("Docker disk usage (raw)") {
                    Text(df).font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            if !ds.projects.isEmpty {
                Section("Compose projects (\(ds.projects.count))") {
                    ForEach(ds.projects) { project in
                        dockerProjectRow(project)
                    }
                }
            }
            if !ds.standaloneImages.isEmpty {
                Section("Standalone images (\(ds.standaloneImages.count))") {
                    ForEach(ds.standaloneImages) { img in
                        dockerImageRow(img)
                    }
                }
            }
            let stopped = ds.containers.filter { !$0.running }
            if !stopped.isEmpty {
                Section("Stopped containers (\(stopped.count))") {
                    ForEach(stopped) { c in
                        dockerContainerRow(c)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func dockerProjectRow(_ project: DockerComposeProject) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).fontWeight(.medium)
                Text("\(project.images.count) image(s) · ≈ \(project.totalBytes.formattedBytes)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Badge(text: project.running ? "running" : "stopped",
                  tint: project.running ? Theme.Status.good : Theme.Status.caution)
            Button {
                pendingActions = [DockerComposeDownAction(project: project, removeVolumes: removeVolumes)]
                showSheet = true
            } label: {
                Label("Remove project", systemImage: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    @ViewBuilder
    private func dockerImageRow(_ img: DockerImage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(img.dangling ? "dangling" : "\(img.repository):\(img.tag)").fontWeight(.medium)
                Text("\(img.id.prefix(19)) · \(img.sizeBytes.formattedBytes) · \(img.createdSince)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                pendingActions = [DockerImageRemoveAction(image: img)]
                showSheet = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    @ViewBuilder
    private func dockerContainerRow(_ c: DockerContainer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).fontWeight(.medium)
                Text("image \(c.image)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                pendingActions = [DockerContainerRemoveAction(container: c)]
                showSheet = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func scan() async {
        isLoading = true
        let avail = DockerScanner.availability()
        availability = avail
        if avail == .available {
            dockerState = DockerScanner.scan()
            dfTable = DockerScanner.systemDFTable()
        } else {
            dockerState = nil
        }
        isLoading = false
    }

    private func openDocker() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Confirmation sheet for shell-based destructive actions. Mirrors
/// `DeletionConfirmationSheet` but: (1) shows the literal docker command per
/// action, (2) a red no-undo banner, (3) the volume opt-in checkbox for
/// compose-down actions. Outcome lists succeeded/failed with real stderr.
struct DockerActionConfirmationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let actions: [any ShellAction]
    @Binding var removeVolumes: Bool
    @State private var outcome: ShellActionOutcome?
    var onCompleted: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome { outcomeView(outcome) } else { planView }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private var planView: some View {
        @Bindable var state = state

        Text("Docker cleanup").font(.title2.bold())
        Label("This cannot be undone — Docker does not go through the Trash.",
              systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout.weight(.medium))

        if hasComposeDown {
            Toggle("Also remove named volumes (deletes database data)", isOn: $removeVolumes)
                .tint(.red)
        }

        List {
            Section("Commands (\(actions.count))") {
                ForEach(actions) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.displayName).fontWeight(.medium)
                        Text(action.commandSummary)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .listStyle(.bordered)

        Toggle(isOn: $state.dryRun) {
            VStack(alignment: .leading) {
                Text("Dry run")
                Text("Log what would run without touching Docker.").font(.caption).foregroundStyle(.secondary)
            }
        }

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(state.dryRun ? "Preview (Dry Run)" : "Run") { execute() }
                .keyboardShortcut(.defaultAction)
                .tint(state.dryRun ? .blue : .red)
                .disabled(actions.isEmpty)
        }
    }

    private var hasComposeDown: Bool {
        actions.contains { $0 is DockerComposeDownAction }
    }

    private func execute() {
        var toRun = actions
        // Rebuild compose-down actions with the current removeVolumes toggle.
        toRun = toRun.map { action in
            if let cd = action as? DockerComposeDownAction {
                return DockerComposeDownAction(project: cd.project, removeVolumes: removeVolumes)
                    as any ShellAction
            }
            return action
        }
        outcome = state.executeShellActions(toRun, kind: .docker)
    }

    @ViewBuilder
    private func outcomeView(_ outcome: ShellActionOutcome) -> some View {
        Label(outcome.dryRun ? "Dry run — nothing was touched"
              : "Ran \(outcome.succeeded.count) action(s) · ≈ \(outcome.reclaimedBytes.formattedBytes)",
              systemImage: outcome.dryRun ? "eye" : "checkmark.circle")
            .font(.title2.bold())
        List {
            if !outcome.succeeded.isEmpty {
                Section("Succeeded") {
                    ForEach(outcome.succeeded) { a in
                        Label(a.displayName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Status.good)
                    }
                }
            }
            if !outcome.failed.isEmpty {
                Section("Failed") {
                    ForEach(outcome.failed) { f in
                        VStack(alignment: .leading) {
                            Text(f.action.displayName).fontWeight(.medium)
                            Text(f.message).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .listStyle(.bordered)
        HStack {
            Spacer()
            Button("Done") { onCompleted(); dismiss() }.keyboardShortcut(.defaultAction)
        }
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `make app 2>&1 | tail -10`
Expected: build succeeds. Fix any `Badge`/`Theme.Status`/`Card` API mismatches by checking `Sources/MacTidyApp/Views/Theme.swift` and `Shared.swift` for the exact symbols (the repo uses `Badge(text:tint:)`, `Theme.accent`, `Theme.Spacing.*`, `Theme.Status.good/.caution`).

- [ ] **Step 4: Commit**

```bash
git add Sources/MacTidyApp/Views/DockerTab.swift Sources/MacTidyApp/Views/DashboardView.swift
git commit -m "Add Docker cleanup tab + confirmation sheet"
```

---

## Task 7: node_modules grouping in the main cleanup list

**Files:**
- Modify: `Sources/MacTidyApp/Views/DashboardView.swift:271-328` (`categoryDetail`) — add a `.nodeModules`-specific grouped branch + an "Analyze packages" button.

**Interfaces:**
- Consumes: `ScanItem.detail` (already holds the parent project name from `CategoryScanner.buildDirs`), existing `ScanItemRow`, `SelectionFooter`, `NodePackagesInspector`.
- Produces: grouped node_modules list + inspector entry point.

UI change; verified by `make app` + manual launch (this task's Step 3).

- [ ] **Step 1: Replace `categoryDetail` with a grouped branch for node_modules**

In `Sources/MacTidyApp/Views/DashboardView.swift`, replace the body of `categoryDetail(_:)` (lines 271-328). Keep the existing header HStack but add an "Analyze packages" button for `.nodeModules`, and branch the `List` between grouped (node_modules) and flat (everything else). The new implementation:

```swift
    private func categoryDetail(_ category: CoreKit.Category) -> some View {
        let result = state.categoryResults.first { $0.category == category }
        let items = result?.items ?? []
        let selected = items.filter { selection.contains($0.id) }
        return VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.snappy) { drilledCategory = nil }
                } label: {
                    Label("Categories", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Text(category.displayName).font(.title3.bold())
                Spacer()
                if category == .nodeModules {
                    Button { showNodeInspector = true } label: {
                        Label("Analyze packages", systemImage: "shippingbox")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Find orphaned and unused npm packages and run npm prune safely.")
                }
                if !items.isEmpty {
                    Button {
                        let allSelected = items.allSatisfy { selection.contains($0.id) }
                        selection.removeAll()
                        if !allSelected {
                            for item in items { selection.insert(item.id) }
                        }
                    } label: {
                        let allSelected = items.allSatisfy { selection.contains($0.id) }
                        Label(allSelected ? "Deselect All" : "Select All",
                              systemImage: allSelected ? "circle" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Text("\(items.count) item\(items.count == 1 ? "" : "s") · \(result?.totalBytes.formattedBytes ?? "0")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
            Divider()
            if category == .nodeModules {
                nodeModulesList(items: items)
            } else {
                flatList(items: items, category: category)
            }
            SelectionFooter(
                selectedCount: selection.count,
                selectedBytes: selected.reduce(0) { $0 + $1.sizeBytes },
                buttonTitle: "Trash Selected…",
                disabled: false
            ) {
                sheetPlanIsCleanAll = false
                sheetPlan = DeletionPlan(items: selected)
            }
        }
    }

    /// node_modules grouped by parent project so the user isn't scrolling one
    /// flat list across every Node project. Each section is one project, with
    /// per-section select-all (grab a whole project at once) and the project's
    /// total node_modules bytes in the header.
    @ViewBuilder
    private func nodeModulesList(items: [ScanItem]) -> some View {
        let groups = Dictionary(grouping: items, by: { $0.detail ?? "Other" })
            .sorted { (lhs, rhs) in lhs.value.reduce(0) { $0 + $1.sizeBytes } > rhs.value.reduce(0) { $0 + $1.sizeBytes } }
        List {
            if items.isEmpty {
                Text("Nothing found").foregroundStyle(.tertiary)
            }
            ForEach(groups, id: \.key) { projectName, groupItems in
                Section {
                    ForEach(groupItems.sorted { $0.sizeBytes > $1.sizeBytes }) { item in
                        ScanItemRow(item: item, selection: $selection)
                    }
                } header: {
                    HStack {
                        Text(projectName).font(.headline)
                        Spacer()
                        Text("≈ \(groupItems.reduce(0) { $0 + $1.sizeBytes }.formattedBytes)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button {
                            let allSelected = groupItems.allSatisfy { selection.contains($0.id) }
                            if allSelected {
                                for item in groupItems { selection.remove(item.id) }
                            } else {
                                for item in groupItems { selection.insert(item.id) }
                            }
                        } label: {
                            let allSelected = groupItems.allSatisfy { selection.contains($0.id) }
                            Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(allSelected ? Theme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func flatList(items: [ScanItem], category: CoreKit.Category) -> some View {
        List {
            Section {
                if items.isEmpty {
                    Text("Nothing found").foregroundStyle(.tertiary)
                }
                ForEach(items) { item in
                    ScanItemRow(item: item, selection: $selection)
                }
            } footer: {
                Text(category.explanation)
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
```

- [ ] **Step 2: Build**

Run: `make app 2>&1 | tail -10`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacTidyApp/Views/DashboardView.swift
git commit -m "Group node_modules by project in the cleanup list

Adds an Analyze packages button to the node_modules header and a
per-project grouped layout so the list isn't one flat scroll."
```

---

## Task 8: NodePackagesInspector — always show prune + trash

**Files:**
- Modify: `Sources/MacTidyApp/Views/DashboardTabs.swift:460-522` (`projectSection`)

**Interfaces:**
- Consumes: existing `NodeProjectAnalysis.orphaned`/`unused`, `runPrune`, `DeletionPlan`.
- Produces: always-visible prune + trash buttons per project.

UI change; verified by `make app`.

- [ ] **Step 1: Always render the action buttons**

In `Sources/MacTidyApp/Views/DashboardTabs.swift`, in `projectSection(_:)` (around line 509-518), replace the `HStack` that only contains "Trash whole node_modules" with an always-visible pair. The "Run npm prune" button moves out of the `if !analysis.orphaned.isEmpty` block so it always renders (disabled when no orphans). Replace the block from the `if !analysis.orphaned.isEmpty {` through the `HStack { Button { sheetPlan ... } }` with:

```swift
            if !analysis.orphaned.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(analysis.orphaned.count) orphaned packages — not in package.json", systemImage: "checkmark.seal")
                        .font(.caption.bold())
                    Text(analysis.orphaned.joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            if !analysis.unused.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(analysis.unused.count) possibly unused — in package.json but not imported", systemImage: "exclamationmark.triangle")
                        .font(.caption.bold())
                    Text(analysis.unused.joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text("Heuristic — verify before removing. Dynamic imports, polyfill-only deps, and build plugins can cause false positives.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            // Always show both reclaim actions per project.
            HStack {
                Button {
                    Task { await runPrune(in: analysis.projectDir) }
                } label: {
                    Label("Run npm prune", systemImage: "hammer")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(analysis.orphaned.isEmpty)
                .help(analysis.orphaned.isEmpty
                      ? "No orphaned packages detected."
                      : "Safe — removes orphaned packages; the project keeps working. Reversible via npm install.")
                if let status = pruneStatus[analysis.projectDir.path] {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    sheetPlan = DeletionPlan(items: [ScanItem(url: analysis.projectDir.appending(path: "node_modules"),
                                                               sizeBytes: analysis.nodeModulesBytes, isDirectory: true)])
                } label: {
                    Label("Trash whole node_modules", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if analysis.orphaned.isEmpty && analysis.unused.isEmpty {
                Text("Clean — no orphaned or unused packages detected. Trash the whole dir to reclaim all space, then `npm install` to restore.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Safe: npm prune keeps the tree working. Trash whole dir: reversible via Trash, `npm install` to restore.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
```

This removes the old inline prune button + status from inside the orphaned block (they now live in the always-visible HStack), and keeps the orphaned/unused *lists* conditionally rendered.

- [ ] **Step 2: Build**

Run: `make app 2>&1 | tail -10`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacTidyApp/Views/DashboardTabs.swift
git commit -m "Always show npm prune + trash actions per Node project

The prune button was only rendered when orphans were detected, leaving
clean-looking projects with no action at all. Now always visible; disabled
with a tooltip when there's nothing to prune."
```

---

## Task 9: Full verification + sanity launch

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `make test`
Expected: all suites pass, including the 3 new test files (`ShellActionExecutorTests`, `DockerScannerTests`, `DockerActionsTests`) and the new `dockerKind` test, plus all pre-existing tests green (regression guard for the untouched filesystem path).

- [ ] **Step 2: Build the app bundle**

Run: `make app`
Expected: `dist/MacTidy.app` created and codesigned.

- [ ] **Step 3: Launch and smoke-check**

Run: `make run` (or open `dist/MacTidy.app`). Verify in the UI:
- Dashboard has a new "Docker" tab.
- With Docker running: tab shows Compose projects / standalone images / stopped containers; "Remove" opens a sheet with a red no-undo banner and the literal `docker` command; dry-run toggle works.
- With Docker not running: empty state with "Open Docker" button.
- Cleanup → node_modules: list is grouped by project with per-project totals and per-section select-all; "Analyze packages" button opens the inspector; inspector always shows prune (disabled when no orphans) + trash buttons per project.

- [ ] **Step 4: Final commit if any fixups**

If Step 3 surfaced fixes, commit them. Otherwise nothing to commit.

```bash
git status   # confirm clean
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** Section 1 (ShellAction) → Task 1. Section 2 (DockerScanner) → Task 3. Section 3 (Docker actions) → Task 4 + Task 6 sheet. Section 4 (Docker UI) → Task 6. Section 5a (group by project) → Task 7. Section 5b (surface inspector + always-show actions) → Task 7 (button) + Task 8 (inspector). Section 6 (testing) → tests in Tasks 1, 2, 3, 4. Section 7 (rollout) → the per-task commits. CleanupLog.Kind.docker → Task 2. AppState.executeShellActions → Task 5. All spec sections mapped.
- **Placeholders:** none; every code step contains full code. (Task 1 Step 3 includes an explicit correction note for the protocol's `run()` member — implementer must read it.)
- **Type consistency:** `ShellAction.run() -> Shell.Output?` consistent across Task 1 (protocol + TestAction), Task 4 (all 3 actions). `DockerScanner.parseImages/parseContainers` signatures match Task 3 tests. `executeShellActions(_:kind:)` signature matches Task 5 and Task 6's call site. `DockerComposeDownAction(project:removeVolumes:)` matches between Task 4, Task 6 row, and Task 6 sheet rebuild.
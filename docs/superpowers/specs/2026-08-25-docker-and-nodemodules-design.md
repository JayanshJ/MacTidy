# Docker cleanup + node_modules improvements — Design

Date: 2026-08-25
Status: Draft (pending user review)

## Goal

Two user-facing improvements to MacTidy:

1. **Docker cleanup** — a new Docker tab that shows Docker disk usage, groups
   images/containers by Compose project, and lets the user delete whole Compose
   projects (images + containers + networks, volumes opt-in) or individual
   standalone images / stopped containers. Today Docker has no UI at all.
2. **node_modules UX** — the main Cleanup list currently renders every
   `node_modules` folder as one flat, ungrouped list (the "scroll all the way
   down" problem) and the `npm prune` action is hidden in a separate sheet that
   only surfaces when orphans are detected (the "I can't prune them whatsoever"
   problem). Fix both: group by project in the main list, and always show the
   prune / trash actions per project.

A reusable, shell-based destructive path is introduced as a byproduct (Docker is
the first user), so future shell-out actions (brew, etc.) share it.

## Non-goals

- No Docker Compose file editing, no image building/pushing, no container logs
  or exec. This is cleanup only.
- No emptying the host Trash. (Existing invariant; unchanged.)
- No changes to the filesystem destructive pipeline (`SafePathPolicy` /
  `Trasher` / `DeletionExecutor`). That path is untouched.
- No removal of the existing `NodePackagesInspector` sheet — it is reused, just
  made more discoverable.

## Key architectural constraint

Docker deletion is **irreversible**. `docker rmi` / `docker compose down`
operate on image/container/project IDs, not filesystem URLs, and there is no
Trash to restore from. This is a genuine break from the app's "everything goes
to the macOS Trash and is undoable" model. Per user decision, MacTidy will
**execute these directly**, behind a confirmation sheet that is explicit about
the lack of undo, and log the reclaim to `CleanupLog` (not `TrashLog` — there is
no restore).

## Design

### 1. A second destructive path: shell-based actions

The existing pipeline (`ScanItem → DeletionPlan → SafePathPolicy.classify →
Trasher.trash`, move-to-Trash only, undoable via `TrashLog`/`Restorer`) is
filesystem-only and stays untouched. Docker needs a parallel path for actions
that shell out to external tools and are not Trash-undoable.

New file `Sources/CoreKit/Safety/ShellAction.swift`:

```swift
public protocol ShellAction: Identifiable, Sendable {
    var id: UUID { get }
    var displayName: String { get }      // "Image postgres:15", "Compose project myapp"
    var commandSummary: String { get }   // literal: "docker rmi -f abc123"
    var reversible: Bool { get }         // Docker actions: false
    var estimatedBytes: Int64 { get }    // for the confirmation total + CleanupLog
}

public struct ShellActionOutcome: Sendable {
    public struct Failure: Identifiable, Sendable {
        public let id: UUID
        public let action: any ShellAction
        public let message: String  // real stderr, surfaced to the user
    }
    public var succeeded: [any ShellAction]
    public var failed: [Failure]
    public var dryRun: Bool
    public var reclaimedBytes: Int64 { succeeded.reduce(0) { $0 + $1.estimatedBytes } }
}

public enum ShellActionExecutor {
    /// Per-item fail-closed: one action's failure skips only itself, never
    /// aborts the rest. dryRun logs the command it would run and reports all
    /// as "would-run" succeeded (no execution).
    public static func execute(_ actions: [any ShellAction], dryRun: Bool) -> ShellActionOutcome
}
```

- `execute` shells out via the existing `Shell.run` (`Sources/CoreKit/Support/Shell.swift:15`).
- Per-item fail-closed matches `DeletionExecutor`'s philosophy: a failed
  `docker rmi` for one image does not abort the rest.
- `dryRun` reuses the app-wide persisted `dryRun` toggle. In dry run, no command
  is run; the outcome reports each action as would-run with its command summary.

`AppState` gains a non-throwing entry point:

```swift
extension AppState {
    func executeShellActions(_ actions: [any ShellAction], kind: CleanupEntry.Kind) -> ShellActionOutcome
}
```

It calls `ShellActionExecutor.execute` and, on a real (non-dry-run) pass with
reclaimed bytes > 0, appends a `CleanupEntry` so the Overview "freed across N
cleanups" stat stays honest. No `TrashLog`/`Restorer` involvement — these
actions have no undo.

`CleanupEntry.Kind` (in `CleanupLog.swift:8`) gains a `.docker` case.

### 2. Docker data model + scanning

`DockerInfo` (`Sources/CoreKit/Scanning/DockerInfo.swift`) stays as-is for the
raw `docker system df` table (still useful as a secondary detail). A new
structured scanner is added:

New file `Sources/CoreKit/Scanning/DockerScanner.swift`:

```swift
public struct DockerImage: Identifiable, Sendable, Hashable {
    public let id: String          // full image ID (sha256) from docker images --no-trunc
    public let repository: String  // "<none>" when dangling
    public let tag: String
    public let sizeBytes: Int64
    public let createdSince: String
    public var dangling: Bool { repository == "<none>" && tag == "<none>" }
    public var composeProject: String?  // from image inspect label, nil if standalone
}

public struct DockerContainer: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let image: String   // repo:tag or image id
    public let running: Bool
}

public struct DockerComposeProject: Identifiable, Sendable, Hashable {
    public let name: String
    public let images: [DockerImage]
    public var totalBytes: Int64 { images.reduce(0) { $0 + $1.sizeBytes } }
    public var running: Bool   // at least one of its containers is up
}

public struct DockerState: Sendable {
    public var images: [DockerImage]
    public var containers: [DockerContainer]
    public var projects: [DockerComposeProject]
    public var standaloneImages: [DockerImage] { images.filter { $0.composeProject == nil } }
}

public enum DockerScanner {
    public enum Availability: Sendable { case available, notInstalled, notRunning }
    public static func availability() -> Availability
    public static func scan() -> DockerState?   // nil when not available
    public static func systemDFTable() -> String?  // wraps DockerInfo.usage() raw table
}
```

Commands (all via `Shell.run`, degrading to `nil` when `docker` is absent):

- Images: `docker images --no-trunc --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'`
- Containers: `docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}'` (status starting with "Up" → running)
- Project attribution: for each image, `docker image inspect <id> --format '{{ index .Config.Labels "com.docker.compose.project" }}'`; non-empty result → `composeProject`.
- Compose project running-state: a project is "running" if any container whose image belongs to it is in status "Up".

Availability:
- `notInstalled`: `Shell.find("docker") == nil`.
- `notRunning`: docker exists but `docker info` exits non-zero.
- `available`: both succeed.

Size honesty: `docker images` reports each image's shared size. Removing a
project frees roughly the sum of its images' sizes, but shared base layers may
be reclaimed by multiple images — the UI presents the total as an *estimate*
("≈ X reclaimable"), not an exact figure.

### 3. Concrete Docker shell actions

In `Sources/CoreKit/Safety/DockerActions.swift`:

```swift
public struct DockerImageRemoveAction: ShellAction {
    public let image: DockerImage
    public var commandSummary: String { "docker rmi -f \(image.id)" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { image.sizeBytes }
    public var displayName: String { image.repository == "<none>" ? "dangling image \(idPrefix)" : "\(image.repository):\(image.tag)" }
}

public struct DockerComposeDownAction: ShellAction {
    public let project: DockerComposeProject
    public let removeVolumes: Bool
    public var commandSummary: String {
        var cmd = "docker compose -p \(project.name) down --rmi all"
        if removeVolumes { cmd += " --volumes" }
        return cmd
    }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { project.totalBytes }
    public var displayName: String { "Compose project \(project.name)" }
}

public struct DockerContainerRemoveAction: ShellAction {
    public let container: DockerContainer
    public var commandSummary: String { "docker rm \(container.id)" }   // only for stopped containers
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }   // container removal rarely frees disk
    public var displayName: String { "stopped container \(container.name)" }
}
```

Default for compose-down is `--rmi all` **without** `--volumes` (data volumes
preserved); `removeVolumes` is opt-in via the confirmation sheet.

### 4. Docker UI

New `DashboardTab.docker` case in the `DashboardView` segmented bar, with a
container icon. New view `DashboardDocker` in `DashboardTabs.swift`, following
the `DashboardUninstaller` / `DashboardStartup` pattern (`@Environment(AppState.self)`,
`.task { await scan() }`, rescan button).

Layout:

- **Header summary**: a compact "Docker disk usage" row — estimated total
  reclaimable (dangling images + stopped-container removals + removable
  project image sets), plus the raw `docker system df` table as a secondary
  disclosure. "Rescan" button.
- **Compose projects** (DisclosureGroup, expanded by default): one row per
  `DockerComposeProject` — name, image count, total bytes, running-state badge
  ("running"/"stopped"). Checkbox to select; per-row "Remove project" button
  → `DockerComposeDownAction` (no volumes by default).
- **Standalone images** (DisclosureGroup, collapsed): images with
  `composeProject == nil`, largest-first. Row: `repo:tag` (or "dangling"),
  truncated ID, size, dangling badge. Multi-select + "Remove selected images"
  footer → `DockerImageRemoveAction`s. Dangling images pre-selected.
- **Stopped containers** (DisclosureGroup, collapsed): removable stopped
  containers, oldest-first. Multi-select + "Remove selected" footer →
  `DockerContainerRemoveAction`s.

New `DockerActionConfirmationSheet` (parallel to
`DeletionConfirmationSheet`) for shell actions:

- Title + a red banner: "This cannot be undone — Docker does not go through the
  Trash."
- For each action: `displayName`, literal `commandSummary` (monospaced), and
  estimated bytes — same honesty the existing sheet applies to file paths.
- The dry-run toggle (reuses persisted `state.dryRun`).
- The volume opt-in checkbox for compose-down actions (off by default).
- Outcome view: per-action succeeded (green check) / failed (orange, real
  stderr from `ShellActionOutcome.Failure.message`), plus total reclaimed.
  "Done" dismisses and triggers a rescan.

Empty states:
- `notInstalled`: "Docker isn't installed" with a link to docker.com.
- `notRunning`: "Docker is installed but not running" + "Open Docker" button
  (`open -a Docker` via `Shell.run` / `NSWorkspace`).

This sheet is reusable by any future shell action (brew cleanup, etc.).

### 5. node_modules grouping fix

Two changes, both scoped to the `.nodeModules` branch of
`DashboardView.categoryDetail` (currently a flat `List` at
`DashboardView.swift:305`).

**5a. Group by project in the main cleanup list.** For `.nodeModules` only (no
change to other categories), render a `List` of `Section`s grouped by parent
project. A project's `node_modules` entries are grouped under one section whose
header is the project name + the project's total `node_modules` bytes (a project
may have a root `node_modules` plus workspace `node_modules` dirs). Inside each
section, `ScanItemRow`s sorted largest-first. Select-All is per-section (grab a
whole project at once) plus the existing category-wide Select-All. The
`SelectionFooter` "Trash Selected…" stays at the bottom for the whole category.

Grouping key: the existing `ScanItem.detail` already holds the parent project
name (`parent.lastPathComponent`, set in `CategoryScanner.buildDirs`), so grouping
needs no scanner change — it groups on `item.detail`. (If two projects share a
name in different paths, group is by name; acceptable for the cleanup list, and
the `ScanItemRow` subtitle still shows the full "in &lt;project&gt;" context.)

**5b. Surface the Node Packages inspector + always-show actions.**

- Add an "Analyze packages" button to the `.nodeModules` category header (next
  to Select-All) that opens the existing `NodePackagesInspector` sheet. The
  header button in `DashboardView` that currently opens it stays (no regression),
  but the list-level entry point is the discoverable one.
- In `NodePackagesInspector.projectSection` (DashboardTabs.swift:461), always
  show both action buttons per project:
  - "Run npm prune" — enabled when `analysis.orphaned` is non-empty; disabled
    with a tooltip "No orphaned packages detected" when empty. Today this
    button only renders when orphans exist, so a clean project shows no actions
    at all.
  - "Trash whole node_modules" — always enabled (existing behavior).

The safe/reversible captions stay: `npm prune` is labeled "safe, keeps the
tree working"; trash-whole-dir is labeled "reversible via Trash; npm install to
restore". This matches the user's "both options available" choice.

### 6. Testing

Swift Testing (`import Testing`), per repo convention. Run via `make test`
(not `swift test`).

- `DockerScannerTests`: inlined stdout fixtures for `docker images`, `docker
  ps -a`, and `docker image inspect` (label present vs absent). Assert parsed
  `DockerState` — image count, dangling detection, `composeProject`
  attribution, project grouping, `standaloneImages` filter, running-state
  inference. No real Docker required.
- `ShellActionExecutorTests`: test actions wrapping `/bin/true` and `/bin/false`
  to assert per-item fail-closed (one failing action doesn't fail the batch),
  dry-run reports would-run without executing, and `reclaimedBytes` sums
  `estimatedBytes` of succeeded actions only.
- `DockerActionCommandTests`: assert `commandSummary` strings for image-remove,
  compose-down (with and without `--volumes`), container-remove.
- Existing `SafePathPolicy` / `DeletionPlan` / `CloneDedup` / `Scanning` /
  `CategoryScanner` tests are a regression guard for the untouched filesystem
  path — they must stay green unchanged.

No new permissions/entitlements. The app is non-sandboxed and already shells
out via `Shell.run` (npm prune is precedent).

### 7. Rollout / commit shape

On `main` (no feature-branch convention in this repo). Small commits:

1. CoreKit `ShellAction` executor + `CleanupEntry.Kind.docker` + tests.
2. CoreKit `DockerScanner` + `DockerActions` + tests.
3. `AppState.executeShellActions` wiring + `CleanupLog` integration.
4. Docker tab + `DashboardDocker` view + `DockerActionConfirmationSheet`.
5. node_modules grouping + inspector surfacing + always-show actions.

`make test` after (1)–(2); `make app` + sanity launch after (5).

## Open questions / risks

- **Shared-layer double-counting**: removing two images that share base layers
  doesn't free `sizeA + sizeB`. The UI shows project/image totals as *estimates*
  ("≈ X"). The `CleanupLog` records the executor's `reclaimedBytes` (sum of
  `estimatedBytes`), which may over-count; acceptable for a personal-use tool,
  but the Overview stat is an approximation, flagged in the spec.
- **`docker compose` vs `docker-compose`**: on modern Docker the `compose`
  subcommand is built-in; the scanner assumes `docker compose …`. If a user has
  only the legacy `docker-compose` binary, compose-down will fail per-item and
  surface in the failed list — degraded but not broken.
- **Project-name collisions**: grouping node_modules by `item.detail` (parent
  dir name) can merge two same-named projects in different paths. Acceptable for
  the cleanup list; the row subtitle preserves full context.
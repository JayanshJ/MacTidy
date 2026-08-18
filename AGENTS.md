# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

MacTidy is a native SwiftUI macOS app (SwiftPM, no Xcode project) for reclaiming
disk space and auditing startup items. Personal-use, non-sandboxed, ad-hoc or
self-signed. macOS 14+, built with the Command Line Tools (full Xcode not required).

## Build, test, run

```sh
make test   # run the CoreKit safety/scanner suite (Swift Testing)
make app    # release build → dist/MacTidy.app, then codesign
make run    # app + open
make cert   # one-time: create the "MacTidy Signing" self-signed cert so FDA survives rebuilds
make clean
```

- **Always use `make test`, not `swift test`.** With bare Command Line Tools the
  Testing.framework lives outside SwiftPM's default search paths and the
  synthesized runner silently no-ops (runs 0 tests) unless a *global* `-F` flag
  is passed. `make test` injects it via `TEST_FLAGS`. Package.swift adds the same
  flag per-target, but that is **not sufficient** — the runner is a separate module.
  See memory `clt-swift-testing-flags` for the original debugging trail.
- Plain `swift build -c release` works for the app/library; `make app` additionally
  wraps the binary into a real `.app` bundle with `Support/Info.plist` and signs it.
- Never add the App Sandbox entitlement — it breaks the entire tool (FDA scanning,
  `trashItem`, `clonefile`). The app is non-sandboxed by design.

## Architecture

Two SwiftPM targets, strictly layered: **CoreKit** (library, no UI, fully unit-tested)
and **MacTidyApp** (SwiftUI executable depending on CoreKit). Keep CoreKit UI-free
and testable — do not push scanner/safety logic into views.

### The single destructive path (most important invariant)

Every destructive action in the app flows through one pipeline:

```
ScanItem(s) → DeletionPlan → SafePathPolicy.classify (per item) → Trasher.trash (move-to-Trash only)
```

- `Sources/CoreKit/Safety/SafePathPolicy.swift` — **deny-by-default**. A candidate
  must resolve *inside* an allowed root (`home`, `/Applications`, `/usr/local`,
  `/opt/homebrew`, or a user-picked `extraAllowedRoots`). On top of that, a hard
  system denylist (`/System`, `/bin`, `/sbin`, `/usr` except `/usr/local`, `/etc`,
  `/Library/Apple`, …) that **nothing overrides**, plus a critical-directory guard
  (`~`, `~/Library`, `~/Library/Caches`, `~/Downloads`, `/Applications`, … can
  contain deletables but never be trashed wholesale). All paths are
  symlink-resolved (`resolvingSymlinksInPath`) *before* checking, so a link into a
  protected area is rejected wherever it sits. Prefer `classify(_:) -> Result<URL,
  Violation>` (non-throwing, per-item) over `validate(_:)` (throws, strict
  all-or-nothing) — `validate` now delegates to `classify`.
- `Sources/CoreKit/Safety/DeletionPlan.swift` — `DeletionExecutor.execute` is
  **non-throwing and partial**: it partitions candidates via `policy.classify`,
  reports rejected ones as `SkippedRecord`s with the policy reason, and executes
  the rest. Fail-closed *per item* — one bad path skips only itself, it no longer
  aborts the whole plan. `dryRun` defaults to `true` and logs what it *would* trash.
- `Sources/CoreKit/Safety/Trasher.swift` — **the only place that mutates the
  filesystem destructively**, and it only ever calls `FileManager.trashItem`. Never
  `removeItem`. The Trash is the undo button. If trashing fails, skip + report.
- `Sources/CoreKit/Safety/TrashLog.swift` + `Restorer` — the visible undo.
  `TrashLog` persists every trashed item (original + Trash location, date, bytes,
  kind) as JSON in `~/Library/Application Support/MacTidy/`. `Restorer` moves an
  item back out of the Trash to its original path (collision-suffixed, never
  overwrites). Only real (non-dry-run) records are persisted.
- `Sources/CoreKit/Safety/CleanupLog.swift` — the honest reclaim-over-time log:
  one `CleanupEntry` per real cleanup (date, kind, reclaimedBytes, itemCount).
  Powers the "freed across N cleanups" stat on the Overview. `Kind.uninstall`
  is written by the uninstaller path (distinct from generic `.deletion`).
  `pruneOlderThan(days:)` drops entries outside the retention window set in
  Settings (0 = keep forever, bounded by `maxEntries`).
- `CloneDeduplicator` (same `Safety/` folder) is the one other mutator: replaces
  extra duplicate copies with APFS clones (`clonefile` + atomic `RENAME_SWAP`),
  sending the swapped-out originals to Trash. Now also partial (per-target
  `classify`, rejected targets skipped). Same dry-run gating.

Any new destructive feature must route through `SafePathPolicy` + `Trasher` (or
`CloneDeduplicator`), and record to `TrashLog`/`CleanupLog` via `AppState`. Never
bypass the policy, never call `removeItem`, never `rm`. The one exception is
`LaunchItemsAuditor`'s system-domain disable/restore, which moves plists (not
user data) via an `osascript` admin prompt — see below.

### Scanning (read-only)

`Sources/CoreKit/Scanning/`: `DiskScanner` (shared engine, `.totalFileAllocatedSize`
= real on-disk blocks, symlinks not followed so trees can't double-count or escape;
also `largeFiles(under:minSize:)` which skips build/VCS trees to avoid overlap),
`CategoryScanner` (the curated cleanup categories), `AppUninstaller`,
`LaunchItemsAuditor`, `DuplicateFinder` (clone-aware via inode + `F_LOG2PHYS`),
`DockerInfo` (read-only display only — MacTidy never runs `docker system prune`),
`Recommendations` (byte-weighted ranking of scan results into a one-click cleanup
plan — biggest × safest × stalest; suggest-only items surfaced but never
auto-selected), `ScanHistory` (rolling `ScanSnapshot` log capped at 50, powers the
reclaimable trend on the Overview).

**Avoiding double-counting** is a core honesty invariant: the reclaim total on the
Overview sums every category, so categories must not overlap. `devCaches` only
lists caches *outside* `~/Library/Caches` (those are covered by `userCaches`);
`bigFiles` scans Downloads + dev roots and skips `node_modules`/`target`/`.git`/
etc. inside `largeFiles` so it doesn't re-surface what `nodeModules`/`rustTargets`
already list. When adding a category, check it doesn't re-count bytes another
category already claims.

`Sources/CoreKit/FDA/FullDiskAccess.swift` — the TCC probe **opens the TCC database**
rather than `access(2)`, because `access` returns stale answers under TCC. The app
blocks on first launch until FDA is granted; without it `~/Library` scans are
silently incomplete.

`Sources/CoreKit/Support/Shell.swift` — shelling out to optional tools (brew, docker,
launchctl). Degrades gracefully (missing tool → nil, never throws) and does not
consult `$PATH` — only standard locations, so behavior is independent of shell config.

`LaunchItemsAuditor` now toggles all three domains, not just user agents. System
agents/daemons run their `launchctl bootout`/`bootstrap` + plist move via a single
`osascript` "do shell script … with administrator privileges" prompt (no embedded
privileged helper — keeps the SwiftPM/ad-hoc-signing story intact). Disabled
plists are parked in per-domain subfolders of the Disabled folder so Restore sends
each back to the right `LaunchAgents`/`LaunchDaemons` directory. User-cancelled
auth (`-128`) is reported distinctly from a real command failure.

### App layer

`Sources/MacTidyApp/AppState.swift` — `@MainActor @Observable` model. The UI's single
gateway for every destructive action: `AppState.execute(_:extraAllowedRoots:kind:)`
constructs a `DeletionExecutor` with the current `dryRun` and `SafePathPolicy`,
then records to `TrashLog` + `CleanupLog` and sets `lastUndoableOutcome` for the
Undo toast. The uninstaller passes `kind: .uninstall` so its cleanups are bucketed
separately from generic deletions. `execute`/`deduplicate` are non-throwing (policy
issues come back as skipped records). Persisted settings: `dryRun` (on by default),
`extraAllowedRoots` (applied to every action in addition to the policy's built-in
roots), `autoScanOnLaunch`, and `logRetentionDays` (prunes `TrashLog`/`CleanupLog`).
The last scan results are persisted to `~/Library/Application Support/MacTidy/last-
scan.json` and a rolling `ScanHistory` (capped at 50) drives the reclaimable trend
on the Overview. `rescanCategories()` is cancellable and reports per-category
progress. The UI is a **single-window guided flow** (no sidebar): `FlowView`
hosts a `FlowPhase` state machine (`welcome → scanning → dashboard → allClean`)
driven by `AppState`'s flow controller. `startFlow()` runs a category scan plus
an uninstall/launch-item scan in parallel, then lands on the **dashboard**.
The dashboard shows everything at once: a tab bar switches between Cleanup
(category cards grid; tap a card to drill into its items with multi-select +
Trash), Uninstaller, Startup, and Duplicates — all in the new design system.
The first pass is a **dry preview** (`flowPass == .dry`); `startRealPass()`
turns `dryRun` off and stays on the dashboard so the user trashes for real.
`FlowToolbar` carries a Home button and the escape hatches (Browse disk,
Recently Trashed, Settings) as sheets. `DiskView` (List/Map toggle, Map renders
`TreemapView`, a recursive binary-split treemap), `SettingsView`, and `TrashView`
are sheets reachable from the toolbar. `UndoToast` overlays post-cleanup undo.

## Tests

`Tests/CoreKitTests/` uses **Swift Testing** (`import Testing`, `@Suite`, `@Test`,
`#expect`), not XCTest — XCTest isn't available with bare CLT. Tests cover the
safety layer (`SafePathPolicy`, `DeletionPlan`, `CloneDedup`), scanners
(`Scanning`, `CategoryScanner`), `Recommendations` ranking, `FlowAction` model,
`ScanHistory`, log retention pruning, and `LaunchItemsAuditor` helpers. Tests
that exercise real trashing clean up their Trash entry afterwards so
`make test` doesn't litter.
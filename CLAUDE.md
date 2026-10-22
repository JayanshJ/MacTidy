# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
  Powers the "freed across N cleanups" stat on the Overview.
- `CloneDeduplicator` (same `Safety/` folder) is the one other mutator: replaces
  extra duplicate copies with APFS clones (`clonefile` + atomic `RENAME_SWAP`),
  sending the swapped-out originals to Trash. Now also partial (per-target
  `classify`, rejected targets skipped). Same dry-run gating.

Any new destructive feature must route through `SafePathPolicy` + `Trasher` (or
`CloneDeduplicator`), and record to `TrashLog`/`CleanupLog` via `AppState`. Never
bypass the policy, never call `removeItem`, never `rm`.

### Cleanup source registry

`Sources/CoreKit/Model/CleanSource.swift` is the declarative table behind
the `devCaches` and `aiAgents` categories: home-relative path, category,
`Risk` (`safe` / `caution` / `danger`), and `whole` vs per-`children`
listing. Adding a home-rooted cache is one line there. Item-level gating:
`ScanItem.isPreselectable` = category preselectable **and** item risk
`.safe`. Bulk "select safe", scheduled runs, auto-selected recommendations
and the "safe to clear" insight all use it, so Caution/Danger items (VM
disks, models, transcripts, worktrees, installed plugins) are listed but
never preselected. Tests enforce: every source passes `SafePathPolicy`,
paths are unique, and a source may only nest inside a `.children` source
(children owned by another source are skipped, so bytes never double-count).

`SafePathPolicy.credentialPaths` is a hard denylist (SSH/GPG/AWS keys,
`gh` tokens, `~/.claude.json`, Claude/Codex/Gemini auth and settings, the
Hugging Face token…). It also denies every **ancestor** of a secret, so
`~/.claude` or `~/.ssh` can never be trashed wholesale, and it resolves
symlinks so dotfile-managed secrets are protected at their target. Checked
before user-picked roots; nothing overrides it.

### Ignore list, growth, running-app guard

`IgnoreList` (Model/) is read by `CategoryScanner`'s default init and by
`ProjectScanner`, so full scans, scheduled runs and the menu bar quick check all
skip ignored paths without extra wiring. `~/Library/Caches` is itself a
`.children` registry source, so any more specific source inside it (SwiftPM,
pip, Playwright…) is listed once and dropped from User caches. When several
sources match an item, the longest path wins (`CleanSource.source(for:)`).
`ScanSnapshot.categories` (optional, older history still decodes) feeds
`ScanHistory.growers`. `RunningAppGuard` is pure: the confirmation sheet passes
running bundle IDs and shows a warning with a graceful Quit button.

### Projects

`ProjectScanner` (Scanning/) finds git repos under the dev roots (nested ones
too; `~/Developer` may itself be a repo), assigns each build-output item from the
category scan to the deepest repo containing it, and reads git state with
read-only `git --no-optional-locks` calls. Ranking = build-output bytes ×
coldness (fully cold at 180 days of no commit/index/top-level change).
`ProjectArchiver` (Safety/) only *creates* a zip without build output and
verifies it with `unzip -t`; `AppState.archive` then trashes the folder through
the normal pipeline and refuses dev roots or repos that contain other repos.
`GitWorktreePruneAction` is the one git mutation (worktree metadata only).

### Scanning (read-only)

`Sources/CoreKit/Scanning/`: `DiskScanner` (shared engine, `.totalFileAllocatedSize`
= real on-disk blocks, symlinks not followed so trees can't double-count or escape;
also `largeFiles(under:minSize:)` which skips build/VCS trees to avoid overlap),
`CategoryScanner` (the curated cleanup categories), `AppUninstaller`,
`LaunchItemsAuditor`, `DuplicateFinder` (clone-aware via inode + `F_LOG2PHYS`),
`DockerInfo` (read-only display only — MacTidy never runs `docker system prune`).

**Avoiding double-counting** is a core honesty invariant: the reclaim total on the
Overview sums every category, so categories must not overlap. `devCaches` only
lists caches *outside* `~/Library/Caches` (those are covered by `userCaches`);
`bigFiles` scans Downloads + dev roots and skips `node_modules`/`target`/`.git`/
etc. inside `largeFiles` so it doesn't re-surface what `nodeModules`/`rustTargets`
already list. When adding a category, check it doesn't re-count bytes another
category already claims.

`Sources/CoreKit/FDA/FullDiskAccess.swift` — the TCC probe **opens the TCC database**
rather than `access(2)`, because `access` returns stale answers under TCC (it also
lists `~/Library/Safari` as a second probe). `FullDiskAccess.status()` adds a pure
`diagnose` (translocated copy, bare binary, stale grant, ad-hoc signature) and
records the cdhash on grant. Ad-hoc builds are pinned by cdhash, so after a rebuild
the Settings switch stays on but belongs to the old build: that is the classic
"granted but still asking" bug; `make cert` fixes it for good. Onboarding polls
every second, offers Reset old permission (`tccutil reset SystemPolicyAllFiles`,
revoke-only) and Relaunch, and can be skipped into a session-only limited mode.

`Sources/CoreKit/Support/Shell.swift` — shelling out to optional tools (brew, docker,
launchctl). Degrades gracefully (missing tool → nil, never throws) and does not
consult `$PATH` — only standard locations, so behavior is independent of shell config.

### App layer

`Sources/MacTidyApp/AppState.swift` — `@MainActor @Observable` model and the UI's
single gateway for every destructive action (`execute`, `deduplicate`), recording
to `TrashLog` + `CleanupLog` and driving the Undo toast. Also owns navigation
(`section`, `drilledCategory`), live scan progress (`scanPartial`), and the
persisted `appearance` (system/light/dark). The last scan is restored from
`last-scan.json`, so later launches open straight into the app; the welcome screen
shows only when there is no saved scan.

UI structure (`Views/`): `RootView` routes onboarding → welcome → `MainShell`.
`MainShell` is a `NavigationSplitView` sidebar (Overview, Cleanup, Insights ·
Developer · Apps · Files · History) with a boot-volume footer; Settings is a
native `Settings` scene (tabs). Design system lives in `Theme.swift`: adaptive
light/dark color tokens, type ramp, spacing, and components (`Page`,
`PageHeader`, `SurfaceSection` + `RowDivider`, `Meter`, `CapacityBar`,
`EmptyStateView`, `Badge`, `RowButtonStyle`). Rules: one accent, spent on what
can be reclaimed and primary actions; one level of surface (never a card in a
card); no `fixedSize(vertical:)` outside a scroll view (it inflates the window's
minimum height).

**Design QA:** `make app && dist/MacTidy.app/Contents/MacOS/MacTidy --snapshot <dir> [--only overview,cleanup,…]`
renders every screen (plus Settings, the confirmation sheet and the menu bar
panel) in light and dark to PNG using fixture data, then quits. It never scans,
trashes or checks for updates, and logs `LAYOUT OVERFLOW` when a screen's
minimum height exceeds the window.

## Tests

`Tests/CoreKitTests/` uses **Swift Testing** (`import Testing`, `@Suite`, `@Test`,
`#expect`), not XCTest — XCTest isn't available with bare CLT. Tests cover the
safety layer (`SafePathPolicy`, `DeletionPlan`, `CloneDedup`) and scanners
(`Scanning`, `CategoryScanner`). Tests that exercise real trashing clean up their
Trash entry afterwards so `make test` doesn't litter.
<p align="center">
  <img src="assets/logo.svg" width="128" height="128" alt="MacTidy icon">
</p>

<h1 align="center">MacTidy</h1>

<p align="center">
  Reclaim disk space on macOS — <em>honestly</em>.<br>
  No RAM-freeing theater, no fake "speed boosts", no <code>rm</code>.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20SwiftPM-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/tests-36%20passing-30A14E" alt="36 tests passing">
</p>

---

A native macOS app for reclaiming disk space and auditing startup items
**honestly** — no RAM-freeing theater, no fake "speed boosts". Personal-use
tool, non-sandboxed, ad-hoc signed.

Everything destructive flows through one path: a `DeletionPlan` validated by
a hard `SafePathPolicy` denylist, executed as **move-to-Trash only** (never
`rm`), with a dry-run mode that's on by default until you switch it off.

## Install

There is **no prebuilt download** — MacTidy isn't notarized or distributed as a
release, so you build it yourself. It takes about a minute.

**Requirements**

- macOS 14 (Sonoma) or newer, Apple Silicon or Intel
- Xcode Command Line Tools — full Xcode is *not* required. If you don't have
  them: `xcode-select --install`

**Steps**

```sh
git clone https://github.com/JayanshJ/MacTidy.git
cd MacTidy
make cert   # one-time: self-signed cert, so Full Disk Access survives rebuilds
make app    # release build → dist/MacTidy.app
```

Then move `dist/MacTidy.app` to `/Applications` (optional, but do it *before*
granting Full Disk Access below — the grant is tied to the app's location):

```sh
mv dist/MacTidy.app /Applications/
```

Use `make run` instead of `make app` to build and launch in one step.

**Grant Full Disk Access (required)**

On first launch MacTidy blocks until you grant it. Open **System Settings →
Privacy & Security → Full Disk Access**, click **+**, and add `MacTidy.app`.
This isn't optional gatekeeping — without FDA, macOS hides parts of
`~/Library` from the scanner and MacTidy would quietly under-report what it
found. It refuses to show you an incomplete number.

**First run**

Dry-run mode is **on by default**. Every cleanup just logs what it *would*
trash until you turn dry-run off in the toolbar. When it is off, deletions
still only ever move files to the Trash — MacTidy never calls `rm` — so the
Trash remains your undo, alongside the in-app **Recently Trashed** view.

### Troubleshooting

- **"MacTidy can't be opened because Apple cannot check it for malicious
  software."** Expected for a self-signed local build. Right-click the app →
  **Open** → **Open**, once. (Or `xattr -dr com.apple.quarantine
  /Applications/MacTidy.app`.)
- **The app keeps asking for Full Disk Access after a rebuild.** You skipped
  `make cert`. Ad-hoc signing gives the binary a new identity on every build,
  so macOS drops the grant. Run `make cert`, rebuild, re-add the app once.
- **Re-granting after moving the app.** FDA is per-path — if you move the
  `.app` after granting, remove the old entry and add the new location.

## Development

```sh
make test   # CoreKit safety/scanner suite — 36 tests, Swift Testing
make clean
```

> Note: `swift test` alone won't work with bare Command Line Tools — the
> Testing.framework lives outside the default search paths and SwiftPM's
> synthesized runner silently no-ops without a global `-F` flag. `make test`
> passes the right flags; see the Makefile comment.

**Signing:** `make cert` creates a self-signed "MacTidy Signing" certificate
in the login keychain (one-time; may prompt twice). With it, the FDA grant
survives rebuilds. Without it, `make app` falls back to ad-hoc signing
(`codesign -s -`), whose identity changes every build — macOS then drops the
FDA grant and you must re-add the app after each rebuild.

## Layout

```
Sources/CoreKit/        # no-UI Swift package: scanning + safety, unit-tested
  Safety/               # Trasher, SafePathPolicy, DeletionPlan,
                        # CloneDeduplicator (build FIRST), TrashLog + Restorer,
                        # CleanupLog
  Scanning/             # DiskScanner, CategoryScanner, AppUninstaller,
                        # LaunchItemsAuditor, DuplicateFinder, DockerInfo
  FDA/                  # Full Disk Access probe + Settings deep-link
Sources/MacTidyApp/     # SwiftUI app target (sidebar: Overview · Disk ·
                        # Uninstaller · Startup Items · Duplicates ·
                        # Recently Trashed)
Tests/CoreKitTests/     # Swift Testing suite (36 tests)
Support/Info.plist      # bundle plist used by `make app`
```

## Deviations from the original spec (all in the "safer/better" direction)

1. **`SafePathPolicy` is deny-by-default**, not just a denylist. A candidate
   must resolve *inside* an allowed root (home, `/Applications`,
   `/usr/local`, `/opt/homebrew`, or a folder the user explicitly picked).
   Symlinks are resolved before checking, so a link pointing at `/System`
   is rejected wherever it sits. Critical dirs (`~`, `~/Library`,
   `~/Library/Caches` itself, `~/Downloads` itself, …) can contain
   deletable items but can never be trashed wholesale themselves.
2. **The FDA probe opens the TCC database** instead of using
   `isReadableFile` — `access(2)` can return stale answers under TCC;
   `open(2)` is what TCC actually gates.
3. **Per-item granularity for DerivedData and iOS DeviceSupport** (the spec
   named the parent folders): you see and trash per-project / per-OS-version
   entries instead of all-or-nothing.
4. **Build-dir detection requires a sibling marker** — `node_modules` needs
   `package.json`, `target` needs `Cargo.toml` (spec only required the
   marker for Rust). Both stay suggest-only, showing owning project and
   last-modified, and are never bulk-preselected.
5. **Apple apps (`com.apple.*`) are listed but not uninstallable** in the
   uninstaller; leftover matching by app *name* is exact-directory-name
   only (substring name matching is how cleaners eat unrelated data).
   Leftover sweep also covers `~/Library/HTTPStorages` and `~/Library/WebKit`.
6. **Duplicate finder refuses to trash the last copy** — the trash button
   disables if every copy in any set is selected.
6a. **The duplicate finder is clone-aware.** Copies that already share
   storage (APFS clones, hardlinks — detected via inode + `F_LOG2PHYS`
   first-extent probing) are badged and *excluded* from the wasted-space
   number, because reporting them as reclaimable would be a lie. And
   instead of deleting copies, **Deduplicate** replaces extra copies with
   APFS clones of the kept file (`clonefile` + atomic `RENAME_SWAP`): every
   path keeps working with identical content, the space comes back, and the
   replaced originals' bytes still go to the Trash for undo.
6b. **Extra reclaim categories**: local iOS device backups (with device
   name and last-backup date read from each backup's Info.plist,
   suggest-only) and developer tool caches outside `~/Library/Caches`
   (npm, pnpm store, Cargo registry, Gradle). Old installers now include
   `.xip`/`.iso`.
7. **Swift Testing instead of XCTest** — XCTest isn't available with bare
   Command Line Tools; Swift Testing ships in the toolchain.
8. Tests that exercise real trashing **clean up their Trash entries**
   afterwards, so `make test` doesn't litter.
9. **Partial-plan execution.** A policy violation skips only the offending
   item (reported with the reason) instead of aborting the whole plan —
   fail-closed *per item*. One bad path in a 200-item cleanup no longer
   rejects all 200. `SafePathPolicy.classify` returns a `Result` per path;
   the old throwing `validate` is kept for callers that want strict
   all-or-nothing.
10. **Visible undo.** Everything MacTidy trashes is logged
    (`~/Library/Application Support/MacTidy/trash-log.json`) and shown in a
    **Recently Trashed** view with one-click **Restore** (moves the item back
    to its original path; collision-suffixed so nothing is ever overwritten)
    plus a post-cleanup **Undo** toast. Restoring an item that's already been
    emptied from the Trash fails gracefully with a clear message.
11. **Reclaim-over-time history.** Every real (non-dry-run) cleanup is
    recorded and summed on the Overview — "freed X across N cleanups" — the
    honest, auditable counterpart to fake "speed boost" numbers.
12. **More categories**: simulator runtimes, Application Support hoarders,
    large files (>100 MB), and dev caches extended to Go / Maven / Yarn /
    Terraform. Categories are kept non-overlapping so the reclaim total
    never double-counts (e.g. `bigFiles` skips `node_modules`/`target`/`.git`;
    `devCaches` only covers caches outside `~/Library/Caches`).
13. **Disk map.** The Disk explorer has a List/Map toggle; Map renders a
    treemap of the current directory's children, area proportional to
    allocated size, click-to-drill-in. Read-only.
14. **Cancellable scans with progress**, and the last scan is **persisted**
    across relaunches so the app doesn't start blank and re-scan everything.

## Non-goals (kept from the spec)

No RAM purging, no process killing, no timer-based "optimization",
no registry-style cleaning. Docker usage is displayed read-only with the
`docker system prune` command to copy — MacTidy never runs it.

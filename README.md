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
  <img src="https://img.shields.io/badge/tests-277%20passing-30A14E" alt="277 tests passing">
</p>

---

A native macOS app for reclaiming disk space and auditing startup items
**honestly** — no RAM-freeing theater, no fake "speed boosts". Personal-use
tool, non-sandboxed, ad-hoc signed.

Everything destructive flows through one path: a `DeletionPlan` validated by
a hard `SafePathPolicy` denylist, executed as **move-to-Trash only** (never
`rm`), with a dry-run mode that's on by default until you switch it off.

## What it does

### Cleanup
Scans 27 categories of reclaimable disk space — caches, build artifacts, old
installers, device backups, dev tool caches, and more. Multi-select items,
review, and trash them. Everything goes to the Trash (never `rm`), so you can
always undo.

### Uninstaller
Lists every installed app (non-Apple) with its orphaned data in `~/Library` —
Application Support, Caches, Preferences, Saved Application State, Containers,
Logs, Group Containers, and more. Uninstall trashes the app bundle + selected
leftovers, revokes TCC privacy permissions (`tccutil`), and unregisters from
LaunchServices (`lsregister`) — all in one confirmed action.

### Startup Items
Audits login items and launch agents/daemons across all three domains (user,
system, global). Disable stale ones with an admin prompt; restore them later.

### Duplicates
Content-hash (SHA-256) duplicate finder with APFS clone awareness. Copies that
already share storage are excluded from the wasted-space count. **Deduplicate**
replaces extra copies with APFS clones — every path keeps working, the space
comes back, and the swapped originals go to the Trash for undo.

### Docker
Structured Docker scanning — images, containers, Compose projects — with
heuristic attribution. Remove images, tear down Compose projects, remove
containers, and prune the BuildKit cache. MacTidy never runs
`docker system prune` — only targeted per-item removals.

### Developer Terminal
A terminal-styled tab for dev-environment cleanup:

- **Ports & Processes** — every TCP listening port, colorized by runtime
  (Node.js, Python, JVM, Ruby, Go, Docker, Database). Each port has a
  plain-language explanation of what the process is and whether it's safe to
  kill. Per-port kill (SIGTERM) with confirmation.
- **Package Manager Caches** — npm, Yarn, pnpm, Homebrew, and Cargo cache
  sizes with one-click clean actions. Also deletes unavailable iOS Simulator
  runtimes.
- **Docker Volumes** — prunes unused Docker volumes.

### System
Time Machine local snapshot management — list, delete individually, or delete
all. Runs `tmutil deletelocalsnapshots` directly (irreversible, no Trash).

### AI Advisor (optional)
Connect an OpenAI-compatible, Anthropic, or local Ollama model for:
- **Insights** — proactive, context-aware cleanup suggestions
- **Review with AI** — per-item Safe / Review / Keep verdicts on scan results
- **Explain** — what a specific file or folder is and whether it's safe to trash
- **Natural-language cleanup** — "clean up my dev caches" → AI builds a plan

Works identically without AI — falls back to deterministic ranked
recommendations.

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
make test   # CoreKit safety/scanner suite — 277 tests, Swift Testing
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
                        # CloneDeduplicator, ShellAction + ShellActionExecutor,
                        # TrashLog + Restorer, CleanupLog,
                        # DevTerminalActions (kill, cache clean, volume prune)
  Scanning/             # DiskScanner, CategoryScanner, AppUninstaller,
                        # LaunchItemsAuditor, DuplicateFinder, DockerScanner,
                        # PortScanner, DevToolScanner, ProcessScanner,
                        # DockerBuilderCache, TimeMachineSnapshots,
                        # Recommendations, ScanHistory
  FDA/                  # Full Disk Access probe + Settings deep-link
  AI/                   # CleanAdvisor protocol, OpenAI/Anthropic/Ollama adapters
Sources/MacTidyApp/     # SwiftUI app target
  Views/                # DashboardView, FlowView, DeveloperTerminalTab,
                        # UninstallerTab, DockerTab, SystemTab, DuplicatesView,
                        # SettingsView, TrashView, DiskView, etc.
Tests/CoreKitTests/     # Swift Testing suite (256 tests)
Support/Info.plist      # bundle plist used by `make app`
```

## Safety model

Every destructive action flows through one of two pipelines:

**Filesystem (Trash-undoable):**
```
ScanItem(s) → DeletionPlan → SafePathPolicy.classify (per item) → Trasher.trash (move-to-Trash only)
```

**Shell actions (irreversible, confirmed):**
```
ShellAction → ShellActionExecutor (per-item fail-closed) → CleanupLog
```

- `SafePathPolicy` is **deny-by-default**. A candidate must resolve inside an
  allowed root, symlink-resolved before checking. A hard system denylist
  (`/System`, `/bin`, `/usr`, etc.) that nothing overrides.
- `Trasher` only ever calls `FileManager.trashItem` (with an
  `NSWorkspace.recycle` fallback for root-owned bundles). Never `removeItem`,
  never `rm`.
- `ShellAction`s (Docker, Time Machine, dev tool cleanup) show their literal
  command in the confirmation sheet. Per-item fail-closed: one failure doesn't
  abort the batch.
- Everything trashed is logged to `TrashLog` (undoable) and `CleanupLog`
  (reclaim-over-time history).

## Design principles

1. **Honesty over theater.** No fake "speed boosts", no RAM purging, no
   inflated reclaim numbers. Categories don't overlap (no double-counting).
   Clone-aware duplicates don't count shared storage as wasted.
2. **Trash, never delete.** Every filesystem deletion goes to the Trash. The
   Trash is the undo button. Shell actions are the exception (Docker, tmutil)
   and are clearly marked as irreversible.
3. **Deny-by-default safety.** The path policy rejects anything it doesn't
   explicitly recognize as safe. One bad path skips itself, not the whole plan.
4. **Works without AI.** Every AI feature has a deterministic fallback. The
   app is fully functional with no provider configured.
5. **No sandbox, no helper, no notarization.** Non-sandboxed by design (FDA
   scanning, `trashItem`, `clonefile` all require it). Ad-hoc/self-signed.
   Admin commands use `osascript` prompts, not a privileged helper.

## License

Personal-use. See the repository for details.
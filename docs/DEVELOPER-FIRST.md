# MacTidy: developer-first roadmap

Research notes + proposal, 2026-10-22. Goal: make MacTidy the disk tool a
developer reaches for. "Normal" cleanup stays, but as a subset of the
developer experience, not the other way round.

> **Status:** P0 (source registry, risk tiers, AI-agent sources, credential denylist) shipped in `Sources/CoreKit/Model/CleanSource.swift`. Risk calls in 4.1 were corrected after inspecting real directories.

## 1. Thesis

A developer's disk is eaten by things no generic cleaner understands:
per-project build output, package-manager stores, VM disks, model weights,
and (new in 2025–26) AI coding-agent state. Generic cleaners (CleanMyMac,
DaisyDisk) see "a 17 GB file in ~/Library/Containers". A developer tool
must see "Docker Desktop's VM disk; 9 GB of it is reclaimable images".

MacTidy already has the right bones: deny-by-default `SafePathPolicy`,
Trash-only `Trasher`, per-item fail-closed execution, a parallel
`ShellAction` path for tool-native cleanup, and a `DevRootsScanner` that
walks project trees. What's missing is (a) coverage of the sources that
matter in 2026, (b) a project-centric view instead of a category-centric one,
and (c) a scriptable surface.

## 2. Where MacTidy stands vs. the field

| Tool | Model | Coverage | Safety | Gaps MacTidy can exploit |
|---|---|---|---|---|
| **DevCleaner.app** (menu bar) | category | "30+ tools", incl. AI agents | Safe/Warning/Danger tiers, deny-list for session files | closed source, no project view, no CLI |
| **ClearDisk** (OSS menu bar) | category + "project artifact scanner" (23 types) | 79 caches: Xcode Previews/Products, SPM, uv, conda, m2, pub-cache, Playwright, HF, JetBrains, gem, deno… | Safe/Caution/Risky, Trash-first | no tool-native cleaning, no undo log, no git awareness |
| **kondo** (CLI) | **project-centric** | 20+ project types (Cargo, CMake, Composer, Elixir, Godot, Gradle, Jupyter, Pixi, Maven, Node, Pub, Python, SBT, Stack, Swift, Unity, Unreal, Zig, .NET, Cabal, Turbo) | `rm -rf` with a prompt | no GUI, no undo, no system caches |
| **mac-cleanup-py** (CLI) | module list | ~40 modules incl. app caches (Adobe, Arc, Chrome, Telegram…) | none (rm) | no sizes before delete, no undo |
| **npkill / cargo-sweep** | single-type | node_modules / cargo target | prompt | one-trick |
| **MacTidy today** | category (27) + Docker + Dev Terminal | strong on Xcode, JS/Rust/Py/Gradle build dirs, Docker, ports | **best in class**: policy + Trash + TrashLog + CleanupLog + dry-run | no AI-agent sources, no project view, no CLI, Xcode/Python/JVM coverage incomplete |

MacTidy's safety model is already better than every tool above. The work
is coverage and framing, not safety.

## 3. Architecture proposals

### 3.1 One source registry instead of three lists

Today the same knowledge lives in three places: the `Category` enum +
`CategoryScanner` switch, the `(path, label)` tuples in `LibraryScanner`
(devCaches), and `DevTool` + `DevToolScanner` + one `ShellAction` struct per
tool. Adding a source means touching 3–5 files and remembering the
`Recommendations.suggestOnly` set.

Proposal: a single declarative `CleanSource` table in CoreKit:

```swift
struct CleanSource {
    let id: String                 // "python.uv-cache"
    let group: Group               // .xcode, .python, .jvm, .js, .aiAgents, .containers, .ide, .system…
    let title: String
    let why: String                // one line, shown in the card
    let locate: Locate             // .path("~/.cache/uv") | .children("~/Library/Developer/Xcode/DerivedData")
                                   // | .projectDir(name: "target", markers: ["Cargo.toml"])
    let risk: Risk                 // .safe (regenerable) | .caution (re-download / history loss) | .danger (never pre-selected)
    let clean: Clean               // .trash | .tool(ShellAction factory)   — tool wins when the dir is a content-addressed store
    let staleAfter: TimeInterval?  // only recommend if untouched this long
    let detect: (() -> Bool)?      // skip when the tool isn't installed
}
```

`CategoryScanner.scan` becomes "for each source in registry, locate +
size". `Recommendations` reads `risk` + `staleAfter` instead of a hand-kept
switch. Tests enumerate the registry and assert every source resolves under
an allowed root and is classified by `SafePathPolicy`. The destructive path
is untouched: `.trash` still goes `DeletionPlan → classify → Trasher`,
`.tool` still goes `ShellActionExecutor`.

This is deletion, not abstraction: three ad-hoc lists collapse into one
table, and the UI can render groups generically.

### 3.2 Project-centric view ("Projects" tab)

Developers think in repos, not categories. `DevRootsScanner` already walks
every dev root; group its output by nearest enclosing git repo instead of
flattening by category. Per project:

- last commit date / last file mtime → **cold** after 90 days (configurable)
- build artifacts found (`node_modules`, `target`, `.build`, `.venv`, `Pods`,
  `.next`, `__pycache__`…), total reclaimable
- `.git` objects size; detect stale worktrees (`git worktree list --porcelain`)
- actions: *Clean artifacts* (trash via the normal pipeline),
  *Archive* (zip + trash the tree — same pipeline, zip is read-only),
  *Open in Terminal/Finder*

A sort by "cold × reclaimable" is the single most useful screen a
developer cleaner can have (this is kondo's whole value). All read-only
data comes from the existing scanner plus `git log -1 --format=%ct`
through `Shell.run`.

### 3.3 Risk tier on every source, surfaced in the UI

`Recommendations` already has `suggestOnlyCategories` and auto-select
rules. Make risk a first-class property (3.1) and show it on every row:
green **Safe** (regenerable), amber **Caution** (re-download cost, or loses
history — AI-agent transcripts, HF models, Xcode archives), red **Danger**
(never pre-selected — Docker VM disk, simulator devices with data, iOS
backups, AI-agent auth/settings files). DevCleaner's hard deny-list for
session/credential files is worth copying: `~/.claude/.credentials.json`,
`~/.codex/auth.json`, `~/.cursor/**/state.vscdb`, `~/.config/gh/hosts.yml`
and friends go into `SafePathPolicy`'s denylist, not just "danger".

### 3.4 Tool-native over path-trash for content-addressed stores

Rule for the registry: if a directory is a store the tool indexes
(Ollama blobs, HF hub, uv, go mod cache, Docker, Nix), clean through the
tool (`ollama rm`, `hf cache rm`, `uv cache prune`, `go clean -modcache`,
`nix-collect-garbage`) as a `ShellAction`. Trashing blobs by hand corrupts
the store. Dumb directories (DerivedData, `node_modules`, `__pycache__`)
stay on the Trash path because undo is better.

### 3.5 CLI target

Add a third SwiftPM target `mactidy-cli` on CoreKit:

```
mactidy scan [--group xcode,python,ai] [--json]
mactidy clean --source python.uv-cache --dry-run
mactidy projects --cold 90 --json
mactidy undo --last
```

Same policy, same Trash, same `TrashLog`. Developers script and cron
things; `ScheduledRunner` already exists and would drive it. JSON output
also makes MacTidy usable from agents/MCP later without new code.

### 3.6 "Normal mode" is a filter, not a fork

Detect developer-ness at scan time (any dev root with repos, or any of
xcode-select / docker / node / cargo / uv present). If none: hide the
Projects, Docker, Dev Terminal tabs and the dev groups; show System,
Uninstaller, Startup, Duplicates. One app, one pipeline; the subset is
whatever detection finds nothing for.

## 4. New sources

Sizes in the last column are from this Mac (2026-10-22) to show which
matter in practice. ✱ = not covered by any existing category.

### 4.1 AI coding agents ✱ (biggest new category; 5+ GB here)

| Path | What | Risk | Clean | Here |
|---|---|---|---|---|
| `~/.codex/worktrees` | agent git worktrees, may hold unmerged work | caution | trash per worktree | 1.66 GB |
| `~/.codex/packages`, `~/.codex/plugins/cache`, `~/.cache/codex-runtimes` | live runtimes and installed plugins | caution | trash | 0.63 + 0.40 + 1.58 GB |
| `~/.codex/sessions`, `*.sqlite` | transcripts/history | caution | trash, age-based | 0.35 GB |
| `~/.claude/skills`, `~/.claude/plugins/cache` | installed skills (often git clones) and plugins; trashing uninstalls | caution | trash per skill/plugin | 1.29 + 0.10 GB |
| `~/.claude/projects` | session transcripts (needed for `--resume`) | caution | trash entries older than N days | 0.36 GB |
| `~/.claude/debug`, `~/.claude/file-history`, `~/.claude/shell-snapshots`, `~/.claude/telemetry` | logs; reports of `debug/` reaching tens of GB | safe | trash | small here |
| `~/Library/Application Support/Cursor/workspaceStorage`, `~/.cursor/extensions` | per-repo state for deleted repos, extension cache | caution | trash orphans | — |
| `~/.gemini/sessions`, `~/.gemini/checkpoints` | transcripts, staged edits | caution | trash | small |
| `~/.continue/index`, `~/.continue/dev_data` | embeddings (rebuilt) | safe | trash | — |
| `~/.aider/`, `~/.openclaw/cache` | history / output cache | caution / safe | trash | — |
| `~/.ollama/models` (listed today, no action) | model weights | caution | `ollama rm <model>` per model | — |
| `~/.cache/huggingface/hub` ✱, `~/.cache/torch` ✱ | model/dataset weights | caution | `hf cache rm`, trash | — |
| `~/.lmstudio/models` ✱ | model weights | caution | trash per model | — |
| `~/Library/Caches/com.anthropic.claudefordesktop.ShipIt` | Electron updater leftovers | safe | already covered by userCaches | 0.62 GB |

**Never touch:** `CLAUDE.md`/`AGENTS.md`/`GEMINI.md` in repos, `~/.claude/settings.json`,
`~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.codex/config.toml`.
Put the credential files on the hard denylist.

### 4.2 Xcode / Apple (gaps vs ClearDisk)

| Path | Risk | Clean |
|---|---|---|
| `~/Library/Developer/Xcode/UserData/Previews` ✱ (SwiftUI preview simulators) | safe | trash |
| `~/Library/Developer/Xcode/Products` ✱ | safe | trash |
| `~/Library/Caches/org.swift.swiftpm`, `~/.swiftpm` ✱ | safe | trash |
| `~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex` (per-project breakdown via `info.plist` like ClearDisk) | safe | trash |
| `~/Library/Logs/CoreSimulator` ✱ | safe | trash |
| `~/Library/Developer/CoreSimulator/Volumes` ✱ (runtime volumes, 10–40 GB) | caution | `xcrun simctl runtime delete` |
| `~/Library/Developer/Xcode/{watchOS,tvOS,visionOS} DeviceSupport` ✱ | safe | trash |
| `~/Library/Caches/CocoaPods` ✱, `~/Library/Caches/org.carthage.CarthageKit` ✱ | safe | trash |
| `~/Library/Developer/Xcode/Archives` (already listed; add **Xcode-running guard** before any Xcode clean) | caution | — |

### 4.3 Python ✱ (only build dirs/venvs covered today)

`~/Library/Caches/pip`, `~/.cache/uv` (`uv cache prune`), `~/.conda/pkgs` /
`~/miniconda3/pkgs` (`conda clean --all`), `~/Library/Caches/pypoetry`,
`~/.pyenv/versions` (caution: old interpreters), `~/.local/share/virtualenvs`
(pipenv), `~/.cache/pre-commit`, `~/.ipython`, `~/.jupyter` (keep),
`~/.cache/pip`.

### 4.4 JVM / Go / Rust / Ruby / PHP / .NET / Dart / Elixir ✱

| Path | Clean |
|---|---|
| `~/.m2/repository` | trash (caution: offline builds) |
| `~/.gradle/caches/*/transforms`, `~/.gradle/daemon` logs | trash |
| `$GOPATH/pkg/mod` (`~/go/pkg/mod`), `~/Library/Caches/go-build` | `go clean -modcache` / `-cache` |
| `~/.rustup/toolchains` (old toolchains), `~/.cargo/git` | `rustup toolchain list` → `rustup toolchain uninstall`; trash |
| `~/.gem`, `~/.bundle/cache` | `gem cleanup`; trash |
| `~/.composer/cache` | `composer clear-cache` |
| `~/.nuget/packages`, `~/.dotnet` | `dotnet nuget locals all --clear` |
| `~/.pub-cache` | `dart pub cache clean` |
| `~/.mix`, `~/.hex` | trash |
| `~/.cache/bazel`, `~/.cache/ccache`, `~/.cache/sccache` | trash |
| `~/.cache/zig`, `~/.cache/nimble` | trash |
| project dirs: `_build` (mix.exs), `bin/ obj/` (*.csproj), `zig-cache zig-out` (build.zig), `.stack-work` (stack.yaml), `dist-newstyle` (*.cabal), `CMakeFiles/` (CMakeCache.txt), `Saved/ Intermediate/` (*.uproject), `.godot/` (project.godot), `.pixi` (pixi.toml) — kondo's list | trash via `DevRootsScanner` markers |

### 4.5 JS toolchains & version managers ✱

`~/.nvm/versions/node/*` (caution: old Node versions, show which is
`nvm current`), `~/.fnm`, `~/.volta/tools`, `~/.local/share/mise/installs`,
`~/.asdf/installs`, `~/.cache/node-gyp`, `~/.cache/typescript`,
`~/.electron` / `~/.cache/electron`, `~/.cache/pnpm`, `~/.yarn/berry/cache`,
project `.turbo`/`.parcel-cache`/`.vite`/`.cache` dirs.

### 4.6 Browsers for testing ✱

`~/Library/Caches/ms-playwright` (`npx playwright uninstall --all`),
`~/.cache/puppeteer`, `~/Library/Caches/Cypress` (old versions:
`cypress cache prune`), `~/.cache/selenium`.

### 4.7 IDEs ✱

`~/Library/Caches/JetBrains/<Product><oldVersion>` (indexes for versions no
longer installed — compare against `~/Library/Application Support/JetBrains`),
`~/Library/Logs/JetBrains`, VS Code `CachedExtensionVSIXs` (0.7 GB here),
`Cache`, `CachedData`, orphaned `workspaceStorage` entries (folder path in
`workspace.json` no longer exists), Android Studio `~/Library/Caches/Google/AndroidStudio*`.

### 4.8 VMs & containers

Docker Desktop VM disk `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`
(17.2 GB here — show it, never trash it; reclaim via existing image/volume
actions, and surface "VM disk vs. docker system df" so the user sees how
much is actually dead). `~/.orbstack/data/data.img` ✱ (sparse; report
`du`, not logical size), Podman `~/.local/share/containers` ✱, `~/.minikube` ✱,
`~/.kube/cache` ✱, `~/.vagrant.d/boxes` ✱, Parallels/UTM/VirtualBox VM
bundles ✱ (danger: list only), `/nix/store` ✱ (`nix-collect-garbage -d`).

### 4.9 Misc dev

`~/.terraform.d/plugin-cache` (listed), `~/.cache/gh`, `~/.aws/cli/cache`,
`~/.cache/chrome-devtools-mcp`, `~/Library/Caches/Homebrew` (listed) +
`brew autoremove`, git: `git gc` + `git worktree prune` per repo, large
packfiles, `~/.local/share/Trash`-style leftovers from Linux tools.

### 4.10 Everyday ("normal") sources worth adding cheaply

Electron app caches (`Slack`, `Discord`, `Teams`, `Notion`, `Arc`, `Dia` — 0.46 GB here —
under `~/Library/Application Support/<app>/Cache*` and `~/Library/Caches/<bundle>`),
`~/Library/Caches/com.spotify.client`, Chrome/Arc `Service Worker/CacheStorage`,
old `~/Library/Application Support/Google/Chrome/*/Code Cache`, iCloud
"Mobile Documents" evictable files (list only, `brctl evict`). These slot
into the same registry with group `.apps`.

## 5. Developer features beyond deletion

- **DerivedData by project** — read each `info.plist` → show which
  projects own the space; "cold project" rule applies.
- **Git health per repo** — objects size, loose vs packed, stale worktrees,
  stale branches merged into main (list only), `git gc` as a `ShellAction`.
- **Version-manager audit** — installed Node/Python/Rust/Java versions vs.
  the one in use; suggest uninstalling the rest.
- **Xcode-running / Docker-running guard** before touching their stores.
- **Disk forecast** — linear fit over `CleanupLog` + daily free-space
  samples (ClearDisk does this; cheap given `ScanHistory` exists).
- **Which cache is growing** — diff two `ScanHistory` snapshots, surface the
  top growers on the Overview (the `.claude/debug` 42 GB story is exactly
  this).

## 6. Prioritized plan

| P | Work | Why first |
|---|---|---|
| **P0** | AI-agent sources (4.1) as a new group, with credential-file denylist | largest uncovered bytes on a dev Mac today; no competitor does it well; pure registry entries |
| **P0** | Source registry (3.1) + risk tier (3.3) | every later source becomes a one-line addition; collapses three lists |
| **P1** | Xcode/Python/JVM/Go gaps (4.2–4.4) | parity with ClearDisk/DevCleaner |
| **P1** | Projects tab with cold-project ranking (3.2) | the developer mental model; reuses `DevRootsScanner` |
| **P2** | CLI target (3.5) | scripting, cron, agents; CoreKit already UI-free |
| **P2** | Tool-native actions for stores (3.4): ollama, hf, uv, go, conda, rustup, nix | correctness for content-addressed dirs |
| **P3** | Version managers, browsers-for-testing, IDE orphans (4.5–4.7) | long tail |
| **P3** | Git health, forecast, growth diff (5) | differentiation |
| **P3** | Normal-mode filter (3.6) | polish; falls out of detection |

Invariants that do not change: deny-by-default `SafePathPolicy`, Trash-only
`Trasher`, per-item fail-closed, `TrashLog`/`CleanupLog`, dry-run default,
no double-counting across sources (registry test: no two `.trash` sources
may resolve to nested paths).

## Sources

- Xcode cleanup guides: [dev.to pyrx_tech](https://dev.to/pyrx_tech/the-complete-xcode-cleanup-guide-for-iosmacos-developers-reclaim-50-150-gb-2026-2h5j), [cleanwithcrumb simctl commands](https://cleanwithcrumb.com/blog/xcode-disk-space-terminal-commands/), [SPM cache](https://cleanwithcrumb.com/blog/clear-swift-package-manager-cache-mac/), [jonathanspooner script](https://jonathanspooner.com/posts/reclaim-100-gb-from-xcode-the-cleanup-script-i-wish-i-d-written-years-ago)
- Competitors: [ClearDisk](https://github.com/bysiber/cleardisk), [DevCleaner](https://devcleaner.app/), [DevCleaner vs CleanMyMac](https://devcleaner.app/guides/mac-cleaner-for-developers), [dev-cleaner CLI](https://github.com/jemishavasoya/dev-cleaner), [kondo](https://github.com/tbillington/kondo/), [mac-cleanup-py](https://pypi.org/project/mac_cleanup/), [cleanwithcrumb roundup](https://cleanwithcrumb.com/blog/best-mac-cleaner-for-developers-2026/)
- AI agents on disk: [bestagent.dev survey](https://bestagent.dev/what-ai-agents-write-to-disk-2026/), [~/.claude cleanup](https://bestagent.dev/claude-code-disk-usage-cleanup), [claude-code issue 11646](https://github.com/anthropics/claude-code/issues/11646), [Cursor CachedData thread](https://forum.cursor.com/t/old-cache-directories-in-config-cursor-cacheddata-accumulate-indefinitely-without-automatic-cleanup/141573), [Codex SSD writes](https://dev.classmethod.jp/en/articles/ai-coding-cli-ssd-write-issues-investigation/)
- Python/ML caches: [uv cache size](https://pydevtools.com/handbook/how-to/how-to-manage-uv-cache-size.md), [HF/npm/conda/docker caches](https://dev.to/riponcm/how-to-free-up-disk-space-as-a-developer-clear-hugging-face-npm-conda-and-docker-caches-3h21), [AI tool leftovers](https://mole.tw93.fun/blog/how-to-remove-ai-tool-leftovers-mac)
- Containers: [Docker Desktop Mac disk](https://docs.docker.com/desktop/mac/space/), [Docker Mac FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/), [OrbStack data.img](https://help.druva.com/en/articles/9146611-orbstack-is-causing-bloated-storage)
- Browsers: [Playwright install docs](https://playwright.bootcss.com/docs/installation), [system Chrome with Puppeteer/Playwright](https://dev.to/romanpinchuk/stop-downloading-duplicate-browsers-use-system-chrome-with-puppeteer-and-playwright-3flo), [uninstall Playwright](https://www.browserstack.com/guide/uninstall-playwright)
- IDEs: [JetBrains old caches](https://resharper-support.jetbrains.com/hc/en-us/community/posts/360000087690-Remove-old-caches), [JetBrains cache cleaning](https://jetbrains.com/help/rider/2021.1/Cleaning_System_Cache.html), [VS Code cache](https://bobbyhadz.com/blog/vscode-clear-cache)

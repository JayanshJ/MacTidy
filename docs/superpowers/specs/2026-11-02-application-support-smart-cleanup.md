# Understanding Application Support — research and plan

*2026-11-02. Phases 1 and 2 shipped in v1.16.0. Phases 3 and 4 are built and not yet released.*

## The problem, measured

On this Mac, `~/Library` is about 30 GB and **Application Support is 21.8 GB of it**.
The next-largest Library folders are Group Containers (1.2 GB) and Containers (0.4 GB).
The top of Application Support:

| Folder | Size | What it actually is | Right answer |
|---|---|---|---|
| `Claude/vm_bundles/claudevm.bundle` | 10.7 GB | The Linux VM Claude Desktop's Cowork feature runs in (`rootfs.img`, `sessiondata.img`, initrd, kernel). Re-downloaded when Cowork is next used; `sessiondata.img` holds Cowork history. | Trash only if the user doesn't use Cowork; quit Claude first; say it will come back. |
| `ConsciousWave/hermes/installs` | 4.2 GB | Versioned installs of a tool (several versions kept side by side). | Keep the newest, trash superseded versions. |
| `com.apple.wallpaper/aerials` | 1.9 GB | Downloaded aerial wallpapers. macOS re-downloads on demand. | Safe-ish; re-download cost. |
| `Steam/Steam.AppBundle` | 1.2 GB | Steam's own client. | Never touch. Games live in `steamapps`; uninstall them through Steam. |
| `Dia/User Data/Default/Service Worker` | 0.5 GB | Chromium service-worker cache of a browser profile. | Safe with the app quit; sits next to cookies and logins that must not be touched. |
| `Claude/claude-code/2.1.308` | 0.26 GB | A superseded bundled Claude Code version (2.1.309 is current). | Safe. |
| `Claude/Cache` + `Claude/Code Cache` | 0.53 GB | Chromium caches of an Electron app. | Safe with the app quit. |

Five folders, five different right answers. That is why the current category
("here are the 30 biggest folders, suggest-only, no text") doesn't help anyone:
the unit is wrong (whole app folder), and nothing says what a folder is.

The same shape repeats on every developer Mac. The GitHub issues on
`claudevm.bundle` alone report 9–13 GB per machine; a Cursor forum thread
reports a 13.7 GB `Application Support/Cursor`; Mole's maintainers measured a
3.76 GB browser profile of which 3.7 GB was `Service Worker/CacheStorage`.

A generic probe for Chromium/Electron cache folders found **654 MB across 25
folders** here (Claude, Dia, Spline, Codex, Steam, physmap) — all rebuildable, none
of it visible in the app today.

## What the app can do today (audit)

- **Cleanup → Application Support** lists the top 30 children of the folder
  (`LibraryScanner.swift:81-86`). Rows can't be opened. The only text is the
  category sentence. Unknown folders get no risk badge because `risk` falls back
  to `.safe` for anything not in the registry (`CleanSource.swift:191`).
  `MobileSync` is listed here *and* under iOS backups — a double count.
- **Storage by App** maps first-level children of nine Library folders to
  installed apps by exact bundle id or exact (case-sensitive) name
  (`AppStorageAttribution.swift:67-135`). Bugs: Preferences (`<id>.plist`) and
  Saved State (`<id>.savedState`) never match; folders of uninstalled apps
  (orphans) are dropped silently; Apple apps in `/System/Applications` are never
  known. The tab can only trash Caches.
- **Uninstaller** knows the leftover locations for *one* app (app → paths); there
  is no folder → app function to reuse (`AppUninstaller.swift:202-268`).
- **Disk Map** can walk into Application Support and trash any subfolder, with no
  explanation and no warning (`DiskView.swift:113-148`).
- **AI Explain** sends type, size and date — and the folder *name* only if
  "send file paths" is on, which is off by default (`AdvisorPrompts.swift:48-66`,
  `AIConfig.swift:71`). Without an API key there is no per-item fallback at all.
- **RunningAppGuard** has three hard-coded rules (Xcode, Simulator, Android
  Studio); nothing maps an App Support folder to the app that owns it.
- **SafePathPolicy** allows trashing anything below `Application Support`,
  including browser profiles (cookies, `Login Data`), `com.apple.TCC`,
  `CloudDocs`, `MobileSync`, password-manager data and MacTidy's own folder.
- **The registry** only knows fixed home-relative paths. It cannot say
  "`Code Cache` inside any Electron app".

## What others do

- **Kudu** (`rules/darwin/*.json`, 47 rules touching App Support) is almost
  entirely one pattern repeated per app: `<App>/Cache/Cache_Data`,
  `<App>/Code Cache`, `<App>/GPUCache` for Discord, Slack, VS Code, Cursor,
  Windsurf, Notion, Figma, Postman, Signal, 1Password, Bitwarden, Obsidian,
  Linear, Loom, Todoist, Termius, Insomnia, GitHub Desktop, Hyper, Claude…
  plus a few named extras: VS Code family `CachedData`, `CachedExtensionVSIXs`,
  `logs`; Zoom `zoom.us/data/{Cache,GPUCache,logs}`; Adobe
  `Adobe/Common/Media Cache Files`; Steam `appcache/httpcache`,
  `steamapps/shadercache`; Telegram `tdata/user_data`; Epic `Saved/webcache`;
  Minecraft `logs`, `webcache2`; DaVinci `logs`, `CrashDumps`; Java
  `Oracle/Java/Deployment/cache`.
- **Mole** (`lib/clean/app_caches.sh`, 2,200 lines) targets the same Chromium
  folders, treats `Service Worker/CacheStorage` as the big one (per profile and
  per Electron `Partitions/<name>/`), refuses symlinked cache dirs, guards on the
  owning process, and resolves ownership by `mdfind kMDItemCFBundleIdentifier`
  plus a wide list of app roots (`/System/Applications`, Setapp, Caskroom, Input
  Methods) and helper-suffix stripping (`.helper`, `.xpc`…). Its "insights"
  (`cmd/analyze/insights.go`) are a short list: old Downloads, MobileSync, Xcode
  DerivedData/Simulators, Spotify PersistentCache, OrbStack data.
- **mac-cleanup-py** is a flat list of per-app modules (adobe, android, arc,
  teams, obsidian, steam, telegram, xcode, …). No ownership logic.

Takeaway: a rule list is table stakes and mostly one pattern; the thing none of
them do well — and the thing the friends are asking for — is *explaining* a big
folder and giving it the right unit and action.

## Proposal: four layers

### 1. Knowledge — make the registry able to say it

**a. Generic Electron/Chromium cache pattern.** One rule instead of forty:
under any child of Application Support (and under `Partitions/*`,
`User Data/*`, `Containers/*/Data/Library/Application Support/*`), these
subfolders are rebuildable caches:

`Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`,
`DawnWebGPUCache`, `GraphiteDawnCache`, `ShaderCache`, `ScriptCache`,
`blob_storage`, `Crashpad/{completed,pending}`, `logs`, and
`Service Worker/CacheStorage` (+ `ScriptCache`).

Tier: Safe, with "quit <App> first". Exception: `Service Worker/CacheStorage`
inside a *browser* profile (Chrome, Arc, Dia, Brave, Edge, Vivaldi) and inside
Notion partitions is Caution — it can hold a PWA's offline data.
Needs a new `CleanSource.Locate` case (a glob relative to a root), matching in
`source(for:)`, and double-count handling against the enclosing App Support
folder.

**b. Named hoarders with the right unit and tier** (home-relative, App Support
unless stated):

| Path | Tier | Explanation shown to the user |
|---|---|---|
| `Claude/vm_bundles` | Caution | Cowork's Linux VM (~10 GB). Re-downloaded next time Cowork runs; local Cowork history lives in `sessiondata.img`. Quit Claude first. |
| `Claude/claude-code/<version>`, `Claude/claude-code-vm/<version>` | Safe for all but the newest | Bundled Claude Code versions; only the newest is used. |
| `com.apple.wallpaper/aerials` | Caution | Aerial wallpapers; macOS downloads them again when shown. |
| `Spotify/PersistentCache` | Safe | Streaming cache. Offline downloads are elsewhere and are not touched. |
| `Adobe/Common/Media Cache Files`, `Adobe/Common/Media Cache` | Safe | Premiere/After Effects media cache; rebuilt on open. |
| `zoom.us/data/{Cache,GPUCache,logs}` | Safe | |
| `Code`/`Cursor`/`Windsurf`/`VSCodium`/`Antigravity`: `CachedData`, `CachedExtensionVSIXs`, `logs` | Safe | Editor caches and downloaded extension packages. |
| same: `User/workspaceStorage`, `User/History` | Caution | Per-workspace state and local file history. |
| `Steam/appcache/httpcache`, `Steam/steamapps/shadercache` | Safe | |
| `Steam/steamapps/common/*` | Handled elsewhere | Games — uninstall through Steam → Storage. Shown, never trashed. |
| `JetBrains/Toolbox/apps/<ide>/<old version>` | Caution | Superseded IDE versions kept by Toolbox. |
| `Telegram Desktop/tdata/user_data` | Caution | Media cache; re-downloaded from Telegram. |
| `Microsoft Teams/Cache`, `Microsoft/Teams/...` | Safe | |
| `Epic/EpicGamesLauncher/Saved/webcache`, `minecraft/{logs,webcache2}`, `Blackmagic Design/DaVinci Resolve/{logs,CrashDumps}`, `Oracle/Java/Deployment/cache`, `CrashReporter` | Safe | |
| `Google/Chrome`, `Arc/User Data`, `BraveSoftware/Brave-Browser`, `Firefox/Profiles`, `Dia/User Data`, `Vivaldi`: only `*/Service Worker/CacheStorage`, `*/Code Cache`, `*/GPUCache` | Caution | Browser profile caches. Everything else in a profile is logins and history — protected. |
| `MobileSync/Backup` | remove from appSupport | Already the iOS backups category. |

**c. Protect list.** Add to `SafePathPolicy.credentialPaths` (which also denies
every ancestor, so these can never be trashed through a drill-in or Disk Map):
`Library/Application Support/com.apple.TCC`, `…/CloudDocs`, `…/FileProvider`,
`…/iCloud`, `…/AddressBook`, `…/CallHistoryDB`, `…/Knowledge`,
`…/com.apple.sharedfilelist`, `…/MacTidy`, and inside every browser profile:
`Cookies`, `Login Data`, `Login Data For Account`, `Web Data`, `History`,
`Bookmarks`, `Local State`, `key4.db`, `logins.json`, `cookies.sqlite`,
`places.sqlite`; password managers: `1Password` and `Bitwarden` except their
cache subfolders. Pattern support (b/c) needs the same glob machinery as (a).

### 2. Understanding — a per-folder profile, no AI needed

A pure `FolderProfile` (CoreKit, testable) built from cheap signals, used for
App Support, Containers, Group Containers and home dot-folders alike:

- **Owner**: bundle id → app name (case-insensitive) → `CFBundleName` /
  `CFBundleDisplayName` / executable name of installed apps → Spotlight
  `kMDItemCFBundleIdentifier` → a small alias table for the known mismatches
  (`Code` → VS Code, `discord` → Discord, `zoom.us` → Zoom, `Google/Chrome`,
  `Dia` → Dia *not* "Diagnostics Reporter", which is what a naive Spotlight
  name match returns here). Installed-app roots must include
  `/System/Applications`, Setapp and Caskroom (as Mole does).
- **Owner status**: running now · installed, used in the last 30 days
  (`kMDItemLastUsedDate`) · installed, unused 90+ days · not installed (orphan)
  · Apple system component.
- **Content kind**: Chromium cache (folder names, or `index` + `data_0..3` +
  `f_*` files) · logs · **versioned installs** (siblings named like versions →
  all but the newest are superseded; catches `claude-code/2.1.308`,
  `hermes/installs/*`, JetBrains Toolbox, nvm, JDKs) · **VM / disk image**
  (`.img`, `.raw`, `.qcow2`, `.sparsebundle`, `.utm`, `.pvm`, a `.bundle` with
  `rootfs.img`) · media · models (`.gguf`, `.safetensors`, `.bin` > 500 MB) ·
  databases (`.sqlite`, `.db`, `IndexedDB`, `leveldb`) · documents.
- **Activity**: newest modification date inside (sampled, bounded) and growth
  since the last scan (`ScanHistory.growers` already exists).

Each profile yields: a one-sentence *what it is*, a `Risk`, and a recommended
action — **Trash**, **Trash after quitting X**, **Keep (app data)**, **Handled
elsewhere** (Docker tab, Steam, iCloud), or **Uninstall the app instead**.

### 3. Surface — where users see it

- **Cleanup → Application Support becomes a tree.** Row "Claude · 12.0 GB"
  opens to: `vm_bundles` (Caution, sentence, Quit-Claude button if running),
  `Cache` + `Code Cache` (Safe, preselected), `claude-code/2.1.308` (Safe:
  superseded), and a collapsed "App data — keep" group. Reuses the
  `nodeModules` grouping code (`CleanupView.swift:188-217`).
- **Honest totals.** Today "34 GB more worth reviewing" on the Overview counts
  whole App Support folders of apps that are installed and in use. Count only
  leaves with an action (Safe + Caution); show the rest as *understood, kept*.
  Friends' complaint is partly this number: it looks like 20 GB of junk, and
  then nothing can be done about it.
- **Overview insight (deterministic, no API key)**: "Application Support holds
  21.8 GB: 1.2 GB is rebuildable cache, 10.7 GB is Claude's Cowork VM, 4.2 GB
  are superseded versions, 0.9 GB belongs to apps you haven't opened in 90 days."
- **Storage by App**: fix the Preferences/Saved State matcher; add an "Apps no
  longer installed" section (orphans, trashable); per-app "Trash caches" using
  the pattern engine; show last-used.
- **Disk Map rows** get the profile sentence and risk badge; protected paths
  show a lock instead of Trash.
- **RunningAppGuard** becomes generic: owner's bundle id is running → the
  existing warning + Quit button.
- **AI** receives the profile (owner app, kind, top child names and sizes) rather
  than raw paths, so "send file paths" can stay off by default and the model
  still has something to reason about. Use it for the long tail only.

### 4. New sources beyond Application Support

Ranked by how big they tend to be on developer Macs; tier in brackets.

- **Superseded versions** (Safe/Caution): `.nvm/versions/node/*` but the
  current, `Library/Java/JavaVirtualMachines/*`, `/Applications/Xcode-*.app`
  older than the selected one, `Library/Android/sdk/{build-tools,platforms,ndk}/*`
  old entries, JetBrains Toolbox, Flutter `bin/cache`, Unity Hub editors.
- **VMs and container disks** (Danger, show + link): Docker
  `Containers/com.docker.docker/Data/vms/0/data/Docker.raw` (link to the Docker
  tab), OrbStack `Group Containers/*dev.orbstack/data`, UTM
  `Containers/com.utmapp.UTM/Data/Documents/*.utm`, Parallels `~/Parallels`,
  VirtualBox, Vagrant `.vagrant.d/boxes`, `.minikube`, Multipass.
- **Messaging media** (Caution, list only): `Library/Messages/Attachments`,
  WhatsApp `Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media`,
  Telegram, Slack container caches, Outlook container.
- **Apple**: `Library/iTunes/iPhone Software Updates` (`.ipsw`, Safe),
  `Library/Developer/Xcode/DocumentationCache` (Safe),
  `Library/Developer/{XCTestDevices,XCPGDevices}` (Safe), Safari container
  caches, `com.apple.wallpaper/aerials` (above).
- **Dev** (mostly Safe): `~/.local/share/*` (1.1 GB here: uv, pnpm, virtualenvs,
  and `~/.local/share/Trash`), `~/.docker/buildx`, `~/.gem`, `~/.nuget/packages`,
  `~/.ivy2`, `~/.stack`, `~/.cabal`, `~/.opam`, `~/.rbenv/versions`,
  `~/.asdf/installs`, `~/.mix`/`~/.hex`, `~/.julia/artifacts`, `~/.swiftpm`,
  `~/.vscode-server`, `~/.cursor-server`, Homebrew old formula versions
  (`brew cleanup -n` as a ShellAction preview).
- **AI tooling** (Caution): `~/.hermes` (2.8 GB here), `.lmstudio/{extensions,hub}`,
  `~/.agent-reach`, `Application Support/LM-Studio/logs`, `Application
  Support/Codex` caches (covered by the Electron pattern).

## Phased plan

**Phase 1 — the friends' complaint (biggest win first).**
Drill-in tree for App Support; Electron/Chromium pattern (1a) with the
browser-profile Caution exception; protect list (1c); named hoarders (1b) for
Claude, VS Code family, Spotify, Adobe, Zoom, Steam, aerials; generic
RunningAppGuard; remove the MobileSync double count; honest Overview totals.
Measurable on this Mac: 1.2 GB becomes Safe and preselectable inside
Application Support, 10.7 GB gets an honest sentence and a Caution tier, and the
"worth reviewing" number stops counting Steam's own app.

**Phase 2 — understanding.** `FolderProfile` (owner, status, kind, activity),
superseded-version and VM detectors, deterministic Overview insight, Storage by
App fixes and orphans, profile sentences in Disk Map, AI fed by profiles.

**Phase 3 — breadth.** The new sources in §4, "handled elsewhere" actions
(open Steam storage, open Docker tab, iCloud settings), growth-based nudges
("Claude grew 10 GB since last week").

**Phase 4 — long tail.** Per-folder "why is this big?" using the AI with
profiles; consider importing Kudu's JSON rules as a second opinion (check its
license first) and keeping a small telemetry-free "unknown big folder" list to
grow the registry from real machines.

## Decisions to make

1. `Service Worker/CacheStorage`: Safe everywhere, or Caution inside browser
   profiles and Notion (recommended)?
2. `claudevm.bundle`: offer it at all? Recommended: yes, Caution, only when
   Claude isn't running, with the regrow warning.
3. Overview totals: switch to action-only counting (recommended) even though the
   headline number gets smaller.
4. AI context: send owner app + folder kind by default (no paths), or keep the
   model blind unless the toggle is on?

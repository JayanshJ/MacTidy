# Security Policy

## Supported Versions

MacTidy is a personal-use, self-signed macOS app built from source. Security
fixes are applied to the latest `main` branch only — there are no LTS or
backport releases.

| Version | Supported          |
|---------|--------------------|
| latest   | :white_check_mark:  |
| older    | :x:                |

## Reporting a Vulnerability

If you discover a security issue in MacTidy, please **do not open a public
issue**. Instead, report it privately:

1. Email: **security@jayansh.com** (replace with your contact)
2. Or use GitHub's [private vulnerability reporting](https://github.com/JayanshJ/MacTidy/security/advisories/new)

Please include:
- A description of the issue and its potential impact
- Steps to reproduce
- Your assessment of severity

You will receive a response within 48 hours. If the vulnerability is
confirmed, a fix will be prioritized and a GitHub Security Advisory may be
published.

## Security Model

MacTidy is **not notarized** and **not sandboxed** — by design. It requires
Full Disk Access to scan `~/Library` thoroughly. The trust root is:

1. **HTTPS** — all updates are downloaded over HTTPS from GitHub
2. **Self-signed code signing** — the app is signed with a self-signed
   certificate created by `make cert`; the in-app updater verifies the
   signature (`codesign -v`) before installing
3. **Source-built** — users build from source themselves (or via
   `install.sh`), so they can inspect every line before running

### What MacTidy will never do

- **Never calls `rm`** — all filesystem deletions go through `FileManager.trashItem`
  (move-to-Trash only). The one exception is `CloneDeduplicator`, which uses
  APFS `clonefile` + atomic `RENAME_SWAP` to replace duplicates with clones,
  sending the swapped-out originals to the Trash.
- **Never runs `docker system prune`** — only targeted per-item removals.
- **Never sends data anywhere** — all scanning is local. The AI advisor
  feature (optional) makes outbound API calls only to the provider the user
  configures (OpenAI, Anthropic, or local Ollama). No telemetry, no analytics,
  no phoning home.
- **Never modifies system files** — `SafePathPolicy` is deny-by-default with
  a hard denylist (`/System`, `/bin`, `/usr`, etc.) that nothing overrides.

### Destructive actions

Every destructive action flows through one of two pipelines:

1. **Filesystem** → `SafePathPolicy.classify` (per-item) → `Trasher.trash`
   (move-to-Trash, with `NSWorkspace.recycle` fallback for root-owned items)
2. **Shell actions** → `ShellAction` protocol → `ShellActionExecutor`
   (per-item fail-closed) — shown verbatim in a confirmation sheet before
   running

Both are recorded in `CleanupLog` (reclaim-over-time). Filesystem deletions
are also recorded in `TrashLog` for one-click Undo.
# Handoff implementation

Implemented the proposed RAM and storage work from `HANDOFF-2026-11-03.md`.
The owner explicitly approved a manual, confirmed Empty Trash action in this chat.
No release was published or installed in `/Applications`.

## RAM

- Helpers inside nested bundles roll up to their outermost app. Memory comes
  from `proc_pid_rusage` physical footprints; unavailable measurements are not
  replaced with summed RSS.
- Session activity observes frontmost changes. Quit suggestions require at
  least five minutes of observed inactivity, low aggregate CPU, and elevated
  pressure or at least 1 GiB swap. The AI resolver applies the same gates.
  Confirmation rechecks eligibility and requests a graceful quit by app identity.
- Bounded session samples flag sustained growth over at least two hours as a
  possible leak, and reset on restart. This is a heuristic, not a diagnosis.
- Login Items displays measured memory for exact executable matches, with
  unknown attribution shown as unavailable.
- Removed the disk-cache purge button and its privileged execution path.

## Storage

- Cleanup has a target-size plan, ordered by recovery cost. Only preselectable
  Safe items start checked. Review items need explicit selection; the final
  confirmation uses `DeletionPlan` and the normal safety pipeline.
- Read-only git checks recognize ignored `dist`, `out`, and `build` folders
  without tracked descendants. `.build` beside an xcodeproj is also recognized.
  New findings are Caution and ranked by size and age. Category scans share one
  classification path, including standalone scans.
- Large Files also scans Documents, Desktop and Movies. Roots are deduplicated;
  recognized build output, installers and screenshots retain their own owner.
- A manual Empty Trash button delegates to Finder after an explicit permanent
  deletion warning. It cannot overlap MacTidy cleanup, deduplication, or restore
  operations. Log reconciliation handles missing items and preserves records
  when access is denied; the Undo toast is reconciled too.
- Free-block change before/after an Empty Trash attempt is stored separately
  from cleanup estimates, so it is not counted again in cleanup totals. Other
  disk activity and external disks limit what this boot-volume measurement says.
- Cleanup history now optionally retains successful original paths. Overview
  flags paths that return within seven days; rows label recently built output.
  Restored data is described as returned, not asserted to be cache regrowth.
- Overview links to a read-only disk breakdown: readable home files, apps,
  shared Library, system memory files, APFS system volumes, snapshot count,
  potentially purgeable space, and an explicitly unexplained remainder.
  Shared blocks and inaccessible data prevent exact file-based accounting.

## Verification

- `make test`: **457 tests passed in 56 suites**, including new memory, planning,
  build-output, recurrence, Finder-result and APFS-accounting cases.
- `make app`: release bundle built and ad-hoc signed; `codesign -v` passed.
- Fixture snapshots: 16 images across light and dark for Overview, Cleanup,
  Insights, Recently Trashed, Memory, Trash nudge, target plan and disk breakdown.
  Inspected the new surfaces; no layout-overflow warnings.
- `git diff --check`: passed.

The restricted runner could not run SwiftPM normally. Verification used writable
temporary compiler caches and the approved execution environment.

Real app quitting, multi-hour live growth, permanent Finder emptying, and the
installed app's in-app update remain manual checks. No owner files were cleaned
or permanently deleted for these checks. The build is in `dist/MacTidy.app`.

# Scan benchmarks

Run `make benchmark` for a generated 6,400-file fixture; set `MACTIDY_BENCHMARK_HOME=1` to opt into scanning the real home directory. No files are trashed. The generated fixture is removed after the run. The category rate uses the number of unique regular files reachable from returned category items; Disk Map uses the total regular-file count in the fixture. These are workload-normalized rates, not syscall counters, and categories can enumerate other files too. File counting is outside the timed scan. RSS is the test process's cumulative peak, not a per-pass delta. Time to first result is the first item or completed category, including empty category results.

“Cold” means a fresh MacTidy in-memory cache; the benchmark does not flush macOS's filesystem cache, and generating/counting the fixture warms it. Warm is a second scan in the same process. Results are a single run and depend on background activity and filesystem state; they are not true cold-disk measurements.

## Baseline — 2026-11-08, Apple M4, macOS 26.6.2, debug build

Before persistent index work:

| Scan | Pass | Full (s) | First result (s) | Files/s | Peak RSS (MiB) |
|---|---|---:|---:|---:|---:|
| Disk Map | cold-app-cache | 0.0027 | 0.0019 | 2,398,887 | 45.2 |
| Disk Map | warm-app-cache | 0.0002 | 0.0001 | 39,045,157 | 45.3 |
| Categories | cold-app-cache | 0.0869 | 0.0003 | 68,687 | 49.5 |
| Categories | warm-app-cache | 0.0847 | 0.0002 | 70,481 | 49.7 |

Category pass reported 5,970 unique matched regular files across 34 categories. The test suite passed 472 tests after adding the benchmark.

## After persistent-index prototype — 2026-11-08, same machine and fixture

| Scan | Pass | Full (s) | First result (s) | Files/s | Peak RSS (MiB) |
|---|---|---:|---:|---:|---:|
| Disk Map | cold-app-cache | 0.0043 | 0.0016 | 1,476,705 | 45.3 |
| Disk Map | warm persistent index | 0.1461 | 0.0005 | 43,793 | 45.7 |
| Categories | cold-app-cache | 0.0961 | 0.0004 | 62,100 | 49.8 |
| Categories | warm-app-cache | 0.0861 | 0.0002 | 69,373 | 49.9 |

The warm Disk Map pass includes opening a new index instance (simulated relaunch), showing the persisted snapshot, and waiting for FSEvents replay and validation. **This small, filesystem-warm fixture did not speed up:** the initial scan was about 1.6× slower (0.0043 vs 0.0027 s) and the completed warm scan about 730× slower (0.1461 vs 0.0002 s) than the previous in-memory-only cache. Time to first cached result was 0.0005 s versus 0.0001 s before. FSEvents startup/validation dominates this tiny workload; results do not predict performance on a larger tree. The previous cache did not survive an app relaunch, whereas the index does. Category scans do not use the index and their changes are noise in this single-run comparison. More measurements are needed before claiming any speedup.

## Long-lived journal and immediate presentation — 2026-11-08

The scale fixture has 204,800 one-byte files in 256 deep directory branches; the same generated fixture was used for the before and after runs and was removed afterward. It occupies roughly 800 MiB of allocated disk space. The real-home run was explicitly opted into and scanned read-only. This is one run per configuration on the same Apple M4/macOS 26.6.2 in debug builds, not a statistically controlled benchmark. Filesystem caches, concurrent activity and an actively changing home directory affect results. Both cold scans are application-cache cold, **not** cold physical-disk scans. RSS is the cumulative test-process high-water mark, including previous phases.

Run the fixture with `make benchmark-scale`; append `MACTIDY_BENCHMARK_CLEAN=1` to remove it afterward. Run the home folder with `MACTIDY_BENCHMARK_HOME=1 make benchmark-scale`. The after benchmark gives the long-lived monitor 400 ms to receive its initial history before the warm pass; the before benchmark started warm immediately. A simulated relaunch constructs a new index instance in the same process; it is not an OS process restart.

The **before completed** column is the previous implementation's total time, including synchronous replay. **After presented** is when all cached rows have been delivered to the UI, not a guarantee of freshness; **after validated** includes the deferred replay/rescans. Cold presentation requires the full scan. First-result times record the first individual item or cached batch. The UI labels historical results while checking them; the index never authorizes deletion.

| Scope | Pass | Before completed (s) | Before first (s) | Before RSS (MiB) | After presented (s) | After validated (s) | After first (s) | After RSS (MiB) |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 204,800 files | Cold | 0.096150 | 0.018941 | 43.9 | 0.487341 | 0.487346 | 0.118147 | 43.9 |
| 204,800 files | Warm | 0.169512 | 0.000669 | 44.2 | 0.000730 | 0.000775 | 0.000701 | 44.0 |
| 204,800 files | Relaunch | 0.013846 | 0.000327 | 44.2 | 0.001620 | 0.073891 | 0.001511 | 44.2 |
| Real home | Cold | 4.844102 | 0.001268 | 46.5 | 5.338959 | 5.338963 | 0.001449 | 46.2 |
| Real home | Warm | 2.132201 | 0.000928 | 46.8 | 0.002964 | 3.217771 | 0.002925 | 46.6 |
| Real home | Relaunch | 1.740998 | 0.000571 | 46.9 | 0.000647 | 3.149425 | 0.000634 | 46.9 |

On this run, **presentation** on the large fixture improved approximately 232× for warm and 8.5× for relaunch compared with the old fully validated path. Home presentation improved approximately 719× and 2,691× respectively. The relaunched home snapshot appeared about 8,250× sooner than the new cold scan, but remained historical until validation finished. These ratios compare foreground presentation with the old blocking completion; they do **not** mean the filesystem was validated that much faster. With active changes, the real-home background validations took longer than the earlier blocking validations.

The target was not met for every metric: first-result latency increased in these single runs, especially on the large-fixture relaunch (0.000327 to 0.001511 s), and cold scans were slower. The cause has not been established; filesystem and system activity varied between runs. Relaunch background validation was also slower than before on both scopes. More repeated, alternating runs in separate processes are needed before concluding that cold or first-result performance improved. A clean, live in-memory watcher skips replay, but an event, a journal gap, expired/corrupt index or changed scope triggers background verification or a full scan. Changes are tracked at immediate-child subtree granularity, so a change deep in a large child rescans that child rather than only the deepest directory.

## Deferred persistence and incremental validation — 2026-11-08

These are medians of **three runs per phase**, on the same Apple M4 and macOS 26.6.2, debug build. The generated fixture is the same 204,800-file deep tree described above. The real-home scan is opt-in and read-only; its contents can change during the measurements. A new index instance simulates relaunch in the same test process. Foreground presentation is not equivalent to validated freshness; validation may continue after cached results are visible. Peak RSS is the cumulative test-process high-water mark. Every run represented in the tables below reported a complete scan.

Commands: `MACTIDY_SCALE_REPEATS=3 make benchmark-scale` and `MACTIDY_SCALE_REPEATS=3 MACTIDY_BENCHMARK_HOME=1 make benchmark-scale`. For the paired direct-scan reference, add `MACTIDY_SCALE_COMPARE=1`. The warm pass allows 400 ms for the long-lived monitor to start. The relaunch pass waits **outside the timed interval** for queued persistence, modeling a relaunch after the write finishes. `MACTIDY_BENCHMARK_CLEAN=1` removes the generated fixture. No command empties Trash.

| Scope | Phase | Before presented (s) | After presented (s) | Before validated (s) | After validated (s) | Before first (s) | After first (s) | Before RSS (MiB) | After RSS (MiB) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 204,800 files | Cold | 0.107030 | 0.395816 | 0.107034 | 0.395835 | 0.030466 | 0.001114 | 44.6 | 45.2 |
| 204,800 files | Warm | 0.000849 | 0.000752 | 0.001097 | 0.000826 | 0.000781 | 0.000731 | 44.6 | 45.2 |
| 204,800 files | Relaunch | 0.000724 | 0.001240 | 0.069752 | 0.068920 | 0.000678 | 0.001169 | 44.7 | 45.3 |
| Real home | Cold | 4.850431 | 2.653333 | 4.850436 | 2.653344 | 0.000593 | 0.000709 | 47.2 | 48.0 |
| Real home | Warm | 0.002393 | 0.003775 | 2.439387 | 1.847913 | 0.002348 | 0.003740 | 47.4 | 48.2 |
| Real home | Relaunch | 0.000764 | 0.000747 | 1.908727 | 1.719503 | 0.000750 | 0.000731 | 47.4 | 48.3 |

The fixture's earlier cold run was made immediately after creating the 204,800 files; later scans followed extensive real-home scanning and a different filesystem-cache state. The later fixture cold median is 3.7× the earlier one, so the requested historical cold target **was not demonstrated**. To isolate the index's overhead under the later conditions, each after run also scanned the same scope with the direct `DiskMapScanner` immediately before the indexed cold scan:

| Scope | Direct cold median (s) | Indexed cold median (s) | Direct first median (s) | Indexed first median (s) |
|---|---:|---:|---:|---:|
| 204,800 files | 0.381400 | 0.395816 | 0.000763 | 0.001114 |
| Real home | 3.637855 | 2.653333 | 0.000505 | 0.000709 |

The paired fixture cold scan was 3.8% slower, within the 10% target relative to its direct reference. The requested **first-result-no-worse** target was not met against that reference (0.351 ms slower on the fixture; 0.204 ms slower on home). Absolute values are small but the difference is real in these samples. The direct scanner is a same-build comparison, not a reconstruction of the prior indexed version; the home directory and filesystem cache can change between the two scans. One earlier after-home batch contained an incomplete cold scan during filesystem activity and was repeated; its three cold values were 3.484, 2.802 and 6.285 seconds, the last incomplete. It is not included in the median table above.

Home warm validation improved about 24% (2.439 to 1.848 s) and relaunch validation about 10% (1.909 to 1.720 s). Both are below the earlier 2.132 s blocking home-scan measurement, although those runs were not controlled for live changes. A replay with no events now returns the indexed aggregates without enumerating children; a Swift Testing case verifies that no item-measurement callback fires. When entries are dirty, the index rescans affected immediate-child subtrees. It chooses a concurrent full scan if the dirty subtrees cover at least 70% of the indexed item count or the previous incremental validation took at least as long as the previous full scan. This is a heuristic based on prior work and timings, not a guarantee that a new validation can never exceed a fresh scan.

**Time-sample findings:** `/usr/bin/sample` captured five seconds of the three-pass real-home test process before and after the change. Captures can span phase boundaries, so these are directional stack samples, not isolated CPU percentages. Before the change, one bulk-walker helper's sampled stack contained 3,010 occurrences in `getattrlistbulk` out of 3,646 in its read/drain path; after, several walker stacks were likewise dominated by `getattrlistbulk` and directory opens. The samples therefore point to filesystem enumeration/I/O rather than index encoding as the dominant observed work. Independently, code inspection found `save` synchronously encoding and atomically writing the index before `.finished`; persistence is now coalesced on a utility queue after the result event, and monitor startup remains after the cold result. Child sizing is bounded to four concurrent tasks. These changes do not alter the deletion pipeline.

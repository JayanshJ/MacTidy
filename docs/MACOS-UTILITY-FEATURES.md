# MacTidy: All-Around macOS Utility Roadmap (5 Features)

MacTidy's core architecture—strict `CoreKit` / `MacTidyApp` layering, `SafePathPolicy` + `Trasher` for files, `ShellAction` command previews for CLI operations, and honest read-only reporting without snake oil—scales naturally beyond disk cleanup into an all-around macOS system and developer utility.

This document specifies the 5 feature pillars and tracks implementation status.

---

## Feature 1: System Vitals & Live Menu Bar
**Status:** Implemented (`SystemVitals`, `AppVitalsState`, `VitalsView`, `MenuBarPanel`, `SettingsView`)

Expand MacTidy from memory-only insights into a real-time, honest macOS system vitals monitor in both the main window and the menu bar popover.

### Core capabilities
1. **Battery & Thermal Health (`CoreKit` + IOKit / `ProcessInfo`):**
   - Read battery presence, charge percentage, charging/AC power state, cycle count, design vs. max capacity (`healthPercent`), temperature, and adapter wattage via IOKit (`IOPSCopyPowerSourcesInfo` + `AppleSmartBattery` registry properties, degrading gracefully on desktop Macs with no battery).
   - Read `ProcessInfo.processInfo.thermalState` (`nominal`, `fair`, `serious`, `critical`) and system uptime / CPU core counts + load averages (`getloadavg`).
2. **CPU & Memory Resource Hogs (`CoreKit` + `MacTidyApp`):**
   - Extend `ProcessScanner` / `AppMemory` with app-level aggregate CPU % and top active CPU consumers alongside top physical-footprint memory apps.
   - Surface top CPU and Memory apps in a dedicated **System Vitals** view/card with safe actions: **Reveal in Finder** and **Quit** (using graceful `NSRunningApplication.terminate()`, never touching `ProcessDenylist` or system-essential processes).
3. **Live Menu Bar Vitals (`MenuBarPanel` + `MenuBarExtra` + `SettingsView`):**
   - Show compact live vitals (CPU load, Memory pressure/swap, Battery/Thermal state) inside `MenuBarPanel` alongside the existing free-disk and reclaimable summary.
   - Add an optional Settings toggle to show a compact live status readout next to the menu bar icon (e.g., Off / Free Disk / Memory Pressure / Battery & CPU).

### Design & honesty guardrails
- Never claim to "cool down" or "boost RAM" magically; report real hardware/OS measurements and mark unavailable metrics honestly (e.g. desktop Macs without batteries).
- Keep sampling low-overhead and off `@MainActor`.

---

## Feature 2: Unified App Inspector, Rosetta 2 & Broken Login Items
**Status:** Implemented (`AppInspector`, `AppInspectorSheet`, `LaunchItemsAuditor`, `StartupTab`)

Connect MacTidy's app-focused views (`Memory`, `App Storage`, `Uninstaller`, `Login Items`, `Dev Tools`) around a single deep inspector and catch silent background cruft.

### Core capabilities
1. **Unified App Inspector Sheet:**
   - Openable from any app row across tabs: shows bundle identifier, version, install path, binary architecture (**Apple Silicon**, **Universal**, or **Intel / Rosetta 2** via Mach-O / `file` / `NSRunningApplication.executableArchitecture`), total data footprint (`Application Support`, `Caches`, `Containers`), running PIDs, listening ports, and registered `LaunchAgents`/`LaunchDaemons`.
2. **Broken Login Items Detection (`LaunchItemsAuditor`):**
   - Check each enabled launch agent/daemon's `Program` / `ProgramArguments[0]` path on disk and flag items whose executable no longer exists ("Missing target binary"), making stale leftovers obvious without guessing.
3. **Privacy & Permissions Overview:**
   - Read-only audit of app permissions where readable, highlighting uninstalled or long-unused apps, paired with one-click deep links to the exact System Settings Privacy & Security pane (`x-apple.systempreferences:com.apple.preference.security?...`).

---

## Feature 3: Developer & Network Toolkit
**Status:** Implemented (`NetworkScanner`, `FlushDNSCacheAction`, `DockerScanner`, `DockerTab`, `DeveloperTerminalTab`)

Make `Dev Tools` and `Docker` a complete daily-driver developer console.

### Core capabilities
1. **Network & DNS Diagnostics (`DeveloperTerminalTab`):**
   - Show active network interfaces (Wi-Fi/Ethernet/VPN), local & gateway IPs, configured DNS servers (`scutil --dns`), and established outbound connections per app alongside listening TCP ports (`PortScanner`).
   - Add a `ShellAction`-confirmed **Flush DNS Cache** command (`dscacheutil -flushcache` / `killall -HUP mDNSResponder` previewed verbatim).
2. **Docker Tab Upgrades (`DockerScanner` + `DockerTab`):**
   - Batch `docker image inspect` and `docker inspect` calls so scans run in constant command overhead regardless of image/container count.
   - Add a **Volumes** section (`docker system df -v` / `docker volume ls`) to inspect and remove dangling/unused volumes directly in the Docker tab.
   - Surface active Docker context (`docker context ls`) for users switching between Docker Desktop, OrbStack, and Colima.

---

## Feature 4: Safe macOS Maintenance & Reversible System Tweaks
**Status:** Implemented (`SystemMaintenance`, `SystemTweaks`, `MaintenanceTab`)

Provide the everyday macOS utilities users usually hunt down Terminal commands for, wrapped in MacTidy's transparent preview-and-confirm UX.

### Core capabilities
1. **Curated macOS Maintenance Actions (`ShellActionConfirmationSheet`):**
   - Explicit, previewed commands for common fixes: rebuild Spotlight index (`mdutil -E`), reset Quick Look cache (`qlmanage -r cache`), clear IconServices cache, and verify/thin Time Machine local snapshots.
2. **Reversible System Tweaks (`defaults`):**
   - Clean toggles for popular macOS settings (Finder show extensions / hidden files, screenshot format & save folder, Dock auto-hide delay, key repeat rate, disable `.DS_Store` on network/USB volumes).
   - Every tweak displays its current value, the exact `defaults write` / `killall` command being applied, and a one-click **Reset to macOS Default** button.

---

## Feature 5: Actionable Space Investigation & Smart Automation
**Status:** Implemented (`WhatChanged`, `ChangeLocator`, `DownloadsHygiene`, `ScheduleMode.scanOnly`, `DiskAccounting.Part.destination`, `WhatChangedView`)

Turn passive space breakdowns and history into guided troubleshooting and gentle automation.

### Core capabilities
1. **Interactive System Data & Growth Drill-Down:**
   - Make `DiskAccountingView` rows interactive links into Disk Map, Snapshots, Trash, or Managed Elsewhere.
   - Expand `ScanHistory.growthReport` and `CleanupEntry.paths` into a dated **"What Changed?"** view showing top growing owners and paths that returned after cleanup, with one-click jump into Disk Map.
2. **Scan-Only Schedules & Downloads Hygiene:**
   - Add a **Scan-only** schedule option in `ScheduleEditor` / `ScheduledRunner` to keep `ScanHistory` and menu bar metrics fresh without deleting anything unattended.
   - Add an optional rule/nudge for old `.dmg` / `.pkg` installers sitting in `~/Downloads` beyond a user-chosen age.

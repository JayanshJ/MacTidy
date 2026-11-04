import Foundation
import Darwin

/// One running process with its resource footprint. Read-only — killing is
/// a separate, user-confirmed step. The honest framing: "freeing RAM" on
/// macOS is mostly about quitting idle apps you won't reopen soon, not
/// magic, since the OS compresses/pages well.
public struct RunningProcess: Identifiable, Sendable, Hashable {
    public let pid: Int32
    public let name: String
    /// The app bundle path if this process belongs to a .app, else nil.
    public let appBundlePath: String?
    /// RSS is retained for diagnostics; app memory uses physicalFootprintBytes.
    public let residentBytes: Int64
    public let cpuPercent: Double
    public let idleSeconds: Double
    public let physicalFootprintBytes: Int64?
    public let executablePath: String?

    public init(pid: Int32, name: String, appBundlePath: String?, residentBytes: Int64,
                cpuPercent: Double, idleSeconds: Double,
                physicalFootprintBytes: Int64? = nil, executablePath: String? = nil) {
        self.pid = pid; self.name = name; self.appBundlePath = appBundlePath
        self.residentBytes = residentBytes; self.cpuPercent = cpuPercent
        self.idleSeconds = idleSeconds; self.physicalFootprintBytes = physicalFootprintBytes
        self.executablePath = executablePath
    }

    public var id: Int32 { pid }

    public var isSafeToQuit: Bool {
        appBundlePath != nil && !ProcessDenylist.isDenied(name)
            && cpuPercent < ProcessScanner.idleCpuThreshold
            && idleSeconds >= ProcessScanner.idleThresholdSeconds
    }

    public var isSystemEssential: Bool {
        appBundlePath == nil || ProcessDenylist.isDenied(name)
    }
}

/// Hard denylist of processes MacTidy will never suggest quitting. Nothing
/// overrides this — same philosophy as `SafePathPolicy` for paths. Killing any
/// of these would crash the session, break the GUI, or destabilize the OS.
public enum ProcessDenylist {
    /// Exact process-name matches that must never be touched.
    public static let names: Set<String> = [
        // Core system
        "kernel_task", "launchd", "launchd_sim", "logd", "usermanagerd",
        "windowserver", "WindowServer", "loginwindow", "Dock", "Finder",
        "SystemUIServer", "ControlCenter", "CoreServicesUIAgent",
        "pboard", "cfprefsd", "distnoted", "cfprefsd", "sandboxd", "amfid",
        "trustd", "symptomsd", "configd", "networkd", "mdnsresponder",
        "bluetoothd", "airportd", "SystemExtensions", "nesessionmanager",
        "thermalmonitord", "powerd", "opendirectoryd", "securityd", "seserviced",
        // MacTidy itself — never suggest quitting the app you're using
        "MacTidy",
    ]

    public static func isDenied(_ name: String) -> Bool {
        names.contains(name)
    }
}

/// Read-only process & memory scanner. Uses `ps` for the per-process table
/// (RSS, CPU, command) — no private API, no entitlements needed. Degrades
/// gracefully: a `ps` failure yields an empty list, never a crash.
public enum ProcessScanner {
    /// Minimum observed time away from the frontmost app.
    public static let idleThresholdSeconds: Double = 300

    /// CPU-quiet is an additional gate, never evidence of inactivity.
    /// if its CPU usage is below this percentage. 1% is a conservative bar —
    /// it catches background helpers and parked apps while excluding
    /// actively-running dev servers, builds, and media playback.
    public static let idleCpuThreshold: Double = 1.0

    public struct MemorySummary: Sendable {
        public let totalBytes: Int64
        public let usedBytes: Int64
        public let freeBytes: Int64
        public let swapUsedBytes: Int64

        public init(totalBytes: Int64, usedBytes: Int64, freeBytes: Int64, swapUsedBytes: Int64) {
            self.totalBytes = totalBytes; self.usedBytes = usedBytes
            self.freeBytes = freeBytes; self.swapUsedBytes = swapUsedBytes
        }
    }

    /// Returns the current process list, sorted by resident RAM descending.
    public static func scan(activity: AppActivity = AppActivity(), now: Date = Date()) -> [RunningProcess] {
        guard let output = Shell.run("/bin/ps", ["-axo", "pid,rss,%cpu,comm"]) else {
            return []
        }
        var procs: [RunningProcess] = []
        for line in output.stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4,
                  let pid = Int32(cols[0]),
                  let rssKB = Int64(cols[1]),
                  let cpu = Double(cols[2]) else { continue }
            // `comm` may contain spaces; rejoin the remainder.
            let comm = cols[3...].joined(separator: " ")
            // If the executable lives inside a .app bundle, attribute to that app
            // so helper/renderer processes roll up to their parent app.
            let (name, bundlePath) = attribute(comm: comm)
            procs.append(RunningProcess(
                pid: pid,
                name: name,
                appBundlePath: bundlePath,
                residentBytes: rssKB * 1024,
                cpuPercent: cpu,
                idleSeconds: bundlePath.map { activity.idleSeconds(for: $0, now: now) } ?? 0,
                physicalFootprintBytes: physicalFootprint(pid: pid),
                executablePath: comm
            ))
        }
        return procs.sorted { $0.residentBytes > $1.residentBytes }
    }

    /// Turns a `ps` comm path into (display name, .app bundle path). If the
    /// executable is inside `Foo.app/Contents/...`, attributes to Foo.app so
    /// helper/renderer processes roll up to their parent app.
    static func attribute(comm: String) -> (name: String, bundlePath: String?) {
        // The outermost bundle owns nested Electron helper apps.
        let components = URL(fileURLWithPath: comm).pathComponents
        if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let path = NSString.path(withComponents: Array(components[...index]))
            return (URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path)
        }
        // No .app ancestor — system process; use the bare executable name.
        return ((comm as NSString).lastPathComponent, nil)
    }

    public static func footprint(forExecutable path: String, in processes: [RunningProcess]) -> Int64? {
        let matches = processes.filter { $0.executablePath == path }
        guard !matches.isEmpty, matches.allSatisfy({ $0.physicalFootprintBytes != nil }) else { return nil }
        return matches.reduce(0) { $0 + ($1.physicalFootprintBytes ?? 0) }
    }

    public static func physicalFootprint(pid: Int32) -> Int64? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0, usage.ri_phys_footprint <= UInt64(Int64.max) else { return nil }
        return Int64(usage.ri_phys_footprint)
    }

    /// System-wide memory snapshot from `vm_stat` + `sysctl`. Returns nil if
    /// the tools aren't available (they always are on macOS).
    public static func memorySummary() -> MemorySummary? {
        guard let vm = Shell.run("/usr/bin/vm_stat", []) else { return nil }
        let pagesize = Int64(sysconf(_SC_PAGESIZE))
        let lines = vm.stdout.split(separator: "\n").map { String($0) }

        func pages(_ label: String) -> Int64? {
            guard let line = lines.first(where: { $0.contains(label) }) else { return nil }
            // "Pages free:        12345." → extract the trailing integer.
            let digits = line.split(whereSeparator: { !$0.isNumber })
            return digits.last.flatMap { Int64($0) }
        }

        guard let freePages = pages("Pages free"),
              let active = pages("Pages active"),
              let inactive = pages("Pages inactive"),
              let wired = pages("Pages wired down"),
              let compressed = pages("Pages occupied by compressor"),
              let speculative = pages("Pages speculative") else { return nil }

        let used = (active + wired + compressed + speculative) * pagesize
        let free = (freePages + inactive) * pagesize
        // Total = used + free is approximate; pull the real total via sysctl.
        let total = totalMemoryBytes() ?? (used + free)
        let swap = swapUsedBytes() ?? 0
        return MemorySummary(totalBytes: total, usedBytes: used, freeBytes: free, swapUsedBytes: swap)
    }

    private static func totalMemoryBytes() -> Int64? {
        guard let out = Shell.run("/usr/sbin/sysctl", ["hw.memsize"]) else { return nil }
        let digits = out.stdout.split(whereSeparator: { !$0.isNumber })
        return digits.last.flatMap { Int64($0) }
    }

    private static func swapUsedBytes() -> Int64? {
        guard let out = Shell.run("/usr/sbin/sysctl", ["vm.swapusage"]) else { return nil }
        // "swap used = 1.23G" → rough parse; returns bytes.
        let parts = out.stdout.split(separator: " ")
        for (i, p) in parts.enumerated() where p == "used" && i + 2 < parts.count {
            return parseBytes(parts[i + 2])
        }
        return nil
    }

    /// Parses "1.23G", "456M", "789K" into bytes.
    private static func parseBytes(_ s: Substring) -> Int64? {
        guard let num = Double(s.prefix(while: { $0.isNumber || $0 == "." })) else { return nil }
        let unit = s.last ?? "B"
        switch unit {
        case "G": return Int64(num * 1_073_741_824)
        case "M": return Int64(num * 1_048_576)
        case "K": return Int64(num * 1024)
        default: return Int64(num)
        }
    }
}
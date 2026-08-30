import Foundation

/// A TCP port that's currently listening, attributed to its owning process
/// and classified by the dev runtime it likely belongs to.
public struct PortEntry: Identifiable, Sendable, Hashable {
    public let pid: Int32
    public let port: Int
    public let processName: String
    /// The raw lsof COMMAND column (may be truncated to ~10 chars by lsof).
    public let lsofCommand: String
    public let devRuntime: DevRuntime
    /// The bind address — `*` for all interfaces, `127.0.0.1` for localhost.
    public let bindAddress: String

    /// A plain-language explanation of what this port's process is, written for
    /// non-technical users. Deterministic — comes from a curated glossary + path
    /// heuristics, no AI call needed. Empty when we have nothing useful to say.
    public var explanation: String {
        PortExplanation.explain(processName: processName, lsofCommand: lsofCommand,
                                devRuntime: devRuntime, port: port)
    }

    public var id: String { "\(pid):\(port):\(bindAddress)" }

    public init(pid: Int32, port: Int, processName: String, lsofCommand: String,
                devRuntime: DevRuntime, bindAddress: String) {
        self.pid = pid
        self.port = port
        self.processName = processName
        self.lsofCommand = lsofCommand
        self.devRuntime = devRuntime
        self.bindAddress = bindAddress
    }
}

/// The dev runtime a process likely belongs to, based on its command name.
/// Used to tag ports so the Developer Terminal tab can highlight dev servers.
public enum DevRuntime: String, Sendable, Hashable, CaseIterable {
    case node
    case python
    case java
    case ruby
    case go
    case docker
    case database
    case other

    public var displayName: String {
        switch self {
        case .node: "Node.js"
        case .python: "Python"
        case .java: "JVM"
        case .ruby: "Ruby"
        case .go: "Go"
        case .docker: "Docker"
        case .database: "Database"
        case .other: "Other"
        }
    }

    public var icon: String {
        switch self {
        case .node: "bolt.fill"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .java: "cup.and.saucer.fill"
        case .ruby: "diamond.fill"
        case .go: "building.2.fill"
        case .docker: "cylinder.split.1x2"
        case .database: "cylinder"
        case .other: "questionmark"
        }
    }

    /// A tint color for terminal-style display. Each runtime gets a distinct
    /// color so the port list reads like a colorized terminal output.
    public var terminalColor: String {
        switch self {
        case .node: "green"
        case .python: "yellow"
        case .java: "orange"
        case .ruby: "red"
        case .go: "cyan"
        case .docker: "blue"
        case .database: "purple"
        case .other: "gray"
        }
    }

    /// Classifies a process into a dev runtime. Tries both the attributed
    /// process name (from ProcessScanner, which rolls up .app bundles) and
    /// the raw lsof COMMAND column (which may be truncated but preserves the
    /// original binary name for non-app processes like `com.docker.backend`).
    /// Pure — unit-testable.
    public static func classify(processName: String, lsofCommand: String) -> DevRuntime {
        // Try the attributed name first (e.g. "Docker" from the .app bundle).
        if let r = match(processName) { return r }
        // Fall back to the lsof COMMAND column (e.g. "com.docke" — truncated).
        if let r = match(lsofCommand) { return r }
        return .other
    }

    /// Classifies a single name string. Checks the last path component
    /// (case-insensitive) so `/usr/local/bin/node` and `node` both match.
    private static func match(_ comm: String) -> DevRuntime? {
        let name = (comm as NSString).lastPathComponent.lowercased()
        if ["node", "npm", "npx", "pnpm", "yarn", "bun", "deno", "tsx",
            "vite", "esbuild", "webpack", "next-server"].contains(name) { return .node }
        if name.hasPrefix("python") || ["uvicorn", "gunicorn", "flask", "celery",
            "poetry", "django", "fastapi"].contains(name) { return .python }
        if ["java", "gradle", "kotlin", "kotlinc", "sbt", "scala", "mvn",
            "spring-boot", "tomcat", "jetty"].contains(name) { return .java }
        if ["ruby", "rails", "puma", "sidekiq", "bundle"].contains(name) { return .ruby }
        if ["go", "air", "dlv", "golangci-lint", "cobra"].contains(name) { return .go }
        // Docker: lsof shows "com.docke" (truncated), ProcessScanner shows "Docker".
        // Also match the full backend binary name and VPN/helper names.
        if name == "docker" || name.hasPrefix("com.docker")
            || name == "com.docke" { return .docker }
        // Databases commonly used in dev — postgres, redis, mysql, mongod.
        if name.hasPrefix("postgres") || name.hasPrefix("redis")
            || name.hasPrefix("mysql") || name.hasPrefix("mongo")
            || name == "psql" { return .database }
        return nil
    }

    /// Backward-compatible single-argument classify. Used by tests and any
    /// caller that only has one name. Prefers the two-argument variant when
    /// both names are available.
    public static func classify(_ comm: String) -> DevRuntime {
        classify(processName: comm, lsofCommand: comm)
    }
}

/// Read-only scanner that lists all TCP listening ports and attributes them
/// to their owning process + dev runtime. Runs `lsof` (fast, ~20ms) then a
/// single targeted `ps -p pid1,pid2,... -o pid=,comm=` for just the listening
/// PIDs (~15) — NOT `ProcessScanner.scan()`, which stats all ~500 processes
/// on the machine and was the original bottleneck. Degrades gracefully (empty
/// list on failure, never throws).
public enum PortScanner {
    /// Scans all TCP listening ports. Self-contained — does not call
    /// `ProcessScanner.scan()` (which is slow because it stats every process).
    /// Instead runs lsof, collects the ~15 listening PIDs, then does one
    /// targeted `ps` call for just those PIDs to get full command paths.
    public static func scan() -> [PortEntry] {
        guard let output = Shell.run("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]),
              output.succeeded else { return [] }
        // First pass: parse lsof to get raw entries (PID, port, bind, lsof command).
        // We don't need process names yet — just the PIDs to look up.
        var rawEntries: [(pid: Int32, port: Int, bindAddress: String, lsofCommand: String)] = []
        var seenPIDs = Set<Int32>()
        for line in output.stdout.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 9,
                  let pid = Int32(cols[1]),
                  pid > 1,
                  !ProcessDenylist.isDenied(cols[0]) else { continue }
            let nameCol = cols[8]
            let addressPort = nameCol.split(separator: " ").first.map(String.init) ?? nameCol
            guard let colonIdx = addressPort.lastIndex(of: ":") else { continue }
            let bindAddress = String(addressPort[addressPort.startIndex..<colonIdx])
            guard let port = Int(addressPort[addressPort.index(after: colonIdx)...]) else { continue }
            rawEntries.append((pid, port, bindAddress, cols[0]))
            seenPIDs.insert(pid)
        }

        // Single `ps -p pid1,pid2,... -o pid=,comm=` for just the listening
        // PIDs. This is O(1) processes instead of O(500) — the difference
        // between ~20ms and multi-second hangs.
        let commByPID = lookupComm(for: Array(seenPIDs))

        // Second pass: build PortEntries with the full comm path from ps.
        var entries: [PortEntry] = []
        for raw in rawEntries {
            let fullComm = commByPID[raw.pid] ?? raw.lsofCommand
            // Attribute .app bundle names (e.g. Docker.app → "Docker") so the
            // display name is clean. Same logic as ProcessScanner.attribute but
            // inline so we don't pull in the full ProcessScanner dependency.
            let processName = attributeAppBundle(fullComm) ?? fullComm
            let runtime = DevRuntime.classify(processName: processName, lsofCommand: raw.lsofCommand)
            entries.append(PortEntry(
                pid: raw.pid, port: raw.port,
                processName: processName, lsofCommand: raw.lsofCommand,
                devRuntime: runtime, bindAddress: raw.bindAddress
            ))
        }

        // Deduplicate: lsof lists IPv4 + IPv6 separately for the same port.
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
            .sorted { $0.port < $1.port }
    }

    /// Runs `ps -p pid1,pid2,... -o pid=,comm=` for the given PIDs and returns
    /// a PID → full comm path dictionary. Single shell call regardless of how
    /// many PIDs — much cheaper than `ProcessScanner.scan()` which stats all
    /// ~500 processes on the machine.
    static func lookupComm(for pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map(String.init).joined(separator: ",")
        guard let output = Shell.run("/bin/ps", ["-p", pidList, "-o", "pid=,comm="]),
              output.succeeded else { return [:] }
        return parsePsLookup(output.stdout)
    }

    /// Parses `ps -p ... -o pid=,comm=` output into a PID → comm dictionary.
    /// Each line: `  4521 /usr/local/bin/node` (PID, then full path).
    /// Pure — unit-tested.
    public static func parsePsLookup(_ stdout: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // PID is the first whitespace-delimited token; comm is the rest
            // (may contain spaces, e.g. "com.docker.backend services").
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let pidStr = String(trimmed[trimmed.startIndex..<spaceIdx])
            let comm = String(trimmed[trimmed.index(after: spaceIdx)...])
                .trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidStr), !comm.isEmpty else { continue }
            result[pid] = comm
        }
        return result
    }

    /// If the comm path lives inside a `.app` bundle, returns the app's display
    /// name (e.g. `/Applications/Docker.app/Contents/MacOS/com.docker.backend`
    /// → `"Docker"`). Returns nil for non-app processes. Same walk-up logic as
    /// `ProcessScanner.attribute` but standalone so PortScanner doesn't depend
    /// on the full ProcessScanner scan.
    static func attributeAppBundle(_ comm: String) -> String? {
        var url = URL(fileURLWithPath: comm)
        for _ in 0..<8 {
            if url.pathExtension == "app" {
                return url.deletingPathExtension().lastPathComponent
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == "/" || parent.path == url.path { break }
            url = parent
        }
        return nil
    }
}

/// Plain-language explanations for processes that listen on ports. Deterministic
/// — a curated glossary of known macOS system daemons + common apps, with path
/// heuristics for anything unrecognized. No AI call, instant, always works.
/// Written so a non-technical person can understand what's running on their Mac.
enum PortExplanation {
    /// Returns a one-sentence explanation of what the process is and whether
    /// it's safe to kill. Tries the curated glossary first, then path-based
    /// heuristics, then a runtime-based fallback. Empty string when we truly
    /// don't know.
    static func explain(processName: String, lsofCommand: String,
                        devRuntime: DevRuntime, port: Int) -> String {
        // Try the curated glossary (by process name, then lsof command).
        if let known = glossary(processName) ?? glossary(lsofCommand) {
            return known
        }
        // Try path-based heuristics (e.g. "/System/Library/..." → system service).
        if let inferred = inferFromPath(processName) ?? inferFromPath(lsofCommand) {
            return inferred
        }
        // Runtime-based fallback for dev tools we recognize but don't have a
        // specific glossary entry for.
        return runtimeFallback(devRuntime: devRuntime, port: port, name: processName)
    }

    // MARK: - Curated glossary

    /// Known macOS system daemons and common apps, keyed by the process name
    /// (case-insensitive). Each entry explains what it is in plain language and
    /// whether killing it is safe. Names are matched against both the attributed
    /// process name and the raw lsof COMMAND (which lsof truncates to ~10 chars).
    private static func glossary(_ name: String) -> String? {
        let key = (name as NSString).lastPathComponent.lowercased()
        // Also try the full string lowercased (some entries match on a prefix).
        let fullKey = name.lowercased()

        // macOS system daemons — safe to leave alone, killing may disrupt system.
        let systemDaemons: [String: String] = [
            "rapportd": "Apple's Continuity service. Powers Handoff, AirDrop, and Universal Clipboard between your Apple devices. Safe to leave running — killing it just disables these features until you restart.",
            "controlce": "macOS Control Center. Manages Wi-Fi, Bluetooth, AirDrop, and Focus toggles in your menu bar. Don't kill this — it's a core part of the system interface.",
            "controlcenter": "macOS Control Center. Manages Wi-Fi, Bluetooth, AirDrop, and Focus toggles in your menu bar. Don't kill this — it's a core part of the system interface.",
            "launchd": "macOS's process manager — it starts and supervises every other process. Never kill this; your Mac will stop working properly.",
            "windowserver": "The macOS display compositor. It draws everything you see on screen. Killing it logs you out immediately.",
            "finder": "The macOS file manager. It's the desktop and every file window. Killing it restarts it automatically, but you may lose unsaved folder state.",
            "dock": "The macOS Dock. Killing it restarts automatically.",
            "airportd": "macOS Wi-Fi service. Killing it drops your Wi-Fi connection.",
            "bluetoothd": "macOS Bluetooth service. Killing it disconnects all Bluetooth devices.",
            "configd": "macOS network configuration service. Killing it may drop your network connection.",
            "mdnsresponder": "macOS Bonjour/mDNS service. Handles .local network discovery (AirPlay, AirDrop device finding). Safe to kill but may disrupt discovery.",
        ]

        if let entry = systemDaemons[key] { return entry }
        if let entry = systemDaemons[fullKey] { return entry }

        // Common apps that listen on ports.
        let apps: [String: String] = [
            "spotify": "Spotify music player. Uses this port for its local integration API (Spotify Connect device discovery). Safe to kill — just closes Spotify.",
            "ollama": "Ollama — runs AI language models locally on your Mac. This port is its API server. Killing it stops any apps that are talking to local AI models.",
            "docker": "Docker Desktop. This port is forwarded to a container — a lightweight virtual machine running a service (like a database or web server). Killing it stops the container's published port.",
            "com.docker.backend": "Docker Desktop's backend process. Manages containers and port forwarding. Killing it shuts down Docker.",
            "com.docke": "Docker Desktop's backend process (lsof truncates the name). Manages containers and port forwarding. Killing it shuts down Docker.",
            "ipnextension": "Tailscale VPN. This port is its local coordination service. Killing it disconnects your Tailscale VPN.",
            "ipn": "Tailscale VPN. This port is its local coordination service. Killing it disconnects your Tailscale VPN.",
        ]

        if let entry = apps[key] { return entry }
        if let entry = apps[fullKey] { return entry }

        // Prefix matches for truncated lsof names.
        if fullKey.hasPrefix("com.docker") {
            return "Docker Desktop's backend process. Manages containers and port forwarding. Killing it shuts down Docker."
        }

        return nil
    }

    // MARK: - Path-based heuristics

    /// Infers what a process is from its binary path. If the path is under
    /// `/System/`, it's an Apple system service. If it's under `/Applications/`,
    /// it's a user-installed app. If it's under `/usr/local/` or `/opt/homebrew/`,
    /// it's a Homebrew-installed tool.
    private static func inferFromPath(_ comm: String) -> String? {
        guard comm.contains("/") else { return nil }
        let lower = comm.lowercased()

        if lower.hasPrefix("/system/library/") {
            let appName = (comm as NSString).lastPathComponent
            return "A macOS system process (\(appName)). It's part of macOS itself — generally safe to leave alone. Killing it may disrupt a system feature until you restart."
        }
        if lower.hasPrefix("/applications/") {
            // Extract the .app name.
            if let appName = PortScanner.attributeAppBundle(comm) {
                return "\(appName) — an app you installed. Safe to kill; it just closes the app."
            }
            return "An app in your Applications folder. Safe to kill; it just closes the app."
        }
        if lower.hasPrefix("/usr/local/bin/") || lower.hasPrefix("/opt/homebrew/bin/") {
            let bin = (comm as NSString).lastPathComponent
            return "\(bin) — a command-line tool installed by Homebrew. It's a dev tool or service you installed manually. Safe to kill if you know what it is."
        }
        if lower.hasPrefix("/usr/libexec/") || lower.hasPrefix("/usr/sbin/") {
            let bin = (comm as NSString).lastPathComponent
            return "\(bin) — a macOS system service. Killing it may disrupt the feature it provides."
        }
        return nil
    }

    // MARK: - Runtime-based fallback

    /// When we don't have a specific glossary entry but we recognize the dev
    /// runtime, give a generic explanation based on what that runtime typically does.
    private static func runtimeFallback(devRuntime: DevRuntime, port: Int, name: String) -> String {
        switch devRuntime {
        case .node:
            return "A Node.js process (likely a dev server or build tool). It's probably running a web app, API server, or bundler like Vite/webpack. Safe to kill — restart it from your terminal."
        case .python:
            return "A Python process (likely a web server or script). Common on ports 8000 (Django) or 5000 (Flask). Safe to kill — restart it from your terminal."
        case .java:
            return "A JVM process (Java, Kotlin, or Scala). Likely a Spring Boot app, Tomcat server, or Gradle build daemon. Safe to kill — restart it from your IDE or terminal."
        case .ruby:
            return "A Ruby process (likely Rails or Puma web server). Safe to kill — restart it from your terminal."
        case .go:
            return "A Go process (likely a compiled web server or CLI tool). Safe to kill — restart it from your terminal."
        case .docker:
            return "Docker is forwarding this port to a container. Killing the process stops the container's published port. Manage containers from the Docker tab."
        case .database:
            return "A database server (PostgreSQL, Redis, MySQL, or MongoDB). Killing it stops the database — any apps relying on it will lose their connection."
        case .other:
            return ""
        }
    }
}
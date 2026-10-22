import Foundation

/// A git repository under a dev root, with the build output inside it.
public struct DevProject: Identifiable, Sendable, Hashable {
    public struct Worktree: Sendable, Hashable {
        public let path: URL
        public let branch: String?
        /// The main checkout (first entry of `git worktree list`).
        public let isMain: Bool
        /// Git reports its directory is gone; `git worktree prune` drops it.
        public let isPrunable: Bool

        public init(path: URL, branch: String?, isMain: Bool, isPrunable: Bool) {
            self.path = path
            self.branch = branch
            self.isMain = isMain
            self.isPrunable = isPrunable
        }
    }

    public let url: URL
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public let branch: String?
    public let lastCommit: Date?
    public let lastCommitSubject: String?
    /// Latest of the last commit and the last index change (checkout, stage).
    public let lastActivity: Date?
    public let gitBytes: Int64
    /// Build artifacts from the category scan that live in this repo and in
    /// no deeper one.
    public let artifacts: [ScanItem]
    public let worktrees: [Worktree]
    /// Uncommitted or untracked changes.
    public let isDirty: Bool
    /// Commits not on the upstream branch; nil when there is no upstream.
    public let unpushedCommits: Int?
    /// Other repos live inside this one (e.g. ~/Developer is itself a repo).
    /// Such a folder is never offered for archiving.
    public let containsOtherRepos: Bool

    public var artifactBytes: Int64 { artifacts.reduce(0) { $0 + $1.sizeBytes } }
    public var staleWorktrees: [Worktree] { worktrees.filter(\.isPrunable) }

    public func coldDays(now: Date = .now) -> Int {
        guard let lastActivity else { return 365 }
        return max(0, Int(now.timeIntervalSince(lastActivity) / 86_400))
    }

    /// Ranking: reclaimable bytes weighted by how cold the project is.
    /// Fully cold at 180 days; an active project still counts a little so a
    /// huge fresh build dir isn't invisible.
    public func score(now: Date = .now) -> Double {
        let cold = min(Double(coldDays(now: now)) / 180, 1)
        return Double(artifactBytes) * (0.15 + 0.85 * cold)
    }

    public init(url: URL, branch: String?, lastCommit: Date?, lastCommitSubject: String?,
                lastActivity: Date?, gitBytes: Int64, artifacts: [ScanItem], worktrees: [Worktree],
                isDirty: Bool, unpushedCommits: Int?, containsOtherRepos: Bool) {
        self.url = url
        self.branch = branch
        self.lastCommit = lastCommit
        self.lastCommitSubject = lastCommitSubject
        self.lastActivity = lastActivity
        self.gitBytes = gitBytes
        self.artifacts = artifacts
        self.worktrees = worktrees
        self.isDirty = isDirty
        self.unpushedCommits = unpushedCommits
        self.containsOtherRepos = containsOtherRepos
    }
}

/// Read-only: finds repos and reads their state with non-mutating git
/// commands (`--no-optional-locks`, so even `status` never writes the index).
public enum ProjectScanner {
    /// Build-output categories that belong to a project.
    public static let artifactCategories: Set<Category> = [
        .nodeModules, .rustTargets, .podDirs, .swiftBuildDirs, .gradleBuildDirs,
        .pythonCaches, .jsBuildDirs, .mavenTarget, .phpVendor, .flutterDartTool, .unityLibrary,
    ]

    public static func scan(devRoots: [URL], results: [CategoryResult], now: Date = .now) async -> [DevProject] {
        let repos = findRepos(in: devRoots)
        let artifacts = results.filter { artifactCategories.contains($0.category) }.flatMap(\.items)
        let owner = assign(artifacts, to: repos)
        guard let git = Shell.find("git") else { return [] }

        return await withTaskGroup(of: DevProject.self) { group in
            for repo in repos {
                let mine = owner[repo.path] ?? []
                let nested = repos.contains { $0 != repo && isInside($0.path, repo.path) }
                group.addTask { inspect(repo, git: git, artifacts: mine, containsOtherRepos: nested) }
            }
            var projects: [DevProject] = []
            for await p in group { projects.append(p) }
            return projects.sorted {
                let (a, b) = ($0.score(now: now), $1.score(now: now))
                return a != b ? a > b : $0.coldDays(now: now) > $1.coldDays(now: now)
            }
        }
    }

    // MARK: Discovery

    /// Dirs that never contain a project of their own worth finding.
    static let skipNames: Set<String> = [
        "node_modules", "target", "build", ".build", "Pods", "vendor", "DerivedData",
        ".venv", "venv", "dist", ".next", ".gradle", "Library",
    ]

    /// Every directory holding a `.git` (dir or file, so worktrees and
    /// submodules count), searching inside repos too so nested ones surface.
    // ponytail: depth cap of 6 below each root; raise if people nest deeper.
    static func findRepos(in roots: [URL], maxDepth: Int = 6) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        for root in roots {
            let root = root.resolvingSymlinksInPath()
            if fm.fileExists(atPath: root.appending(path: ".git").path) { found.append(root) }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if walker.level > maxDepth || skipNames.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                if fm.fileExists(atPath: url.appending(path: ".git").path) { found.append(url.resolvingSymlinksInPath()) }
            }
        }
        return Array(Set(found)).sorted { $0.path < $1.path }
    }

    /// Each artifact goes to the deepest repo that contains it.
    static func assign(_ artifacts: [ScanItem], to repos: [URL]) -> [String: [ScanItem]] {
        var owner: [String: [ScanItem]] = [:]
        for item in artifacts {
            let path = item.url.resolvingSymlinksInPath().path
            if let repo = repos.filter({ isInside(path, $0.path) }).max(by: { $0.path.count < $1.path.count }) {
                owner[repo.path, default: []].append(item)
            }
        }
        return owner
    }

    static func isInside(_ path: String, _ dir: String) -> Bool {
        path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    // MARK: Git facts

    static func inspect(_ repo: URL, git: String, artifacts: [ScanItem], containsOtherRepos: Bool) -> DevProject {
        func run(_ args: [String]) -> String? {
            guard let out = Shell.run(git, ["--no-optional-locks", "-C", repo.path] + args), out.succeeded else { return nil }
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lastCommit: Date?
        var subject: String?
        if let line = run(["log", "-1", "--format=%ct%x09%s"]), !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            lastCommit = Double(parts[0]).map(Date.init(timeIntervalSince1970:))
            subject = parts.count > 1 ? parts[1] : nil
        }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"]).flatMap { $0 == "HEAD" ? nil : $0 }
        let dirty = !(run(["status", "--porcelain"]) ?? "").isEmpty
        let unpushed = run(["rev-list", "--count", "@{u}..HEAD"]).flatMap(Int.init)
        let worktrees = parseWorktrees(run(["worktree", "list", "--porcelain"]) ?? "")

        let gitURL = repo.appending(path: ".git")
        var isDir: ObjCBool = false
        let gitIsDir = FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDir) && isDir.boolValue
        let indexDate = gitIsDir
            ? (try? gitURL.appending(path: "index").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            : nil

        // Newest top-level change, so a repo with work but no commits (or old
        // commits and fresh edits) isn't ranked as abandoned.
        let topLevelDate = ((try? FileManager.default.contentsOfDirectory(
            at: repo, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent != ".git" && !skipNames.contains($0.lastPathComponent) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()

        return DevProject(
            url: repo, branch: branch, lastCommit: lastCommit, lastCommitSubject: subject,
            lastActivity: [lastCommit, indexDate, topLevelDate].compactMap { $0 }.max(),
            gitBytes: gitIsDir ? DiskScanner.allocatedSize(of: gitURL) : 0,
            artifacts: artifacts.sorted { $0.sizeBytes > $1.sizeBytes },
            worktrees: worktrees, isDirty: dirty, unpushedCommits: unpushed,
            containsOtherRepos: containsOtherRepos)
    }

    /// Parses `git worktree list --porcelain`: blank-line separated blocks,
    /// the first being the main checkout.
    public static func parseWorktrees(_ text: String) -> [DevProject.Worktree] {
        text.components(separatedBy: "\n\n").enumerated().compactMap { index, block in
            var path: URL?
            var branch: String?
            var prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = URL(fileURLWithPath: String(line.dropFirst(9))) }
                else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                else if line.hasPrefix("prunable") { prunable = true }
            }
            guard let path else { return nil }
            return .init(path: path, branch: branch, isMain: index == 0, isPrunable: prunable)
        }
    }
}

/// `git worktree prune`: drops git's bookkeeping for worktrees whose folders
/// are already gone. Touches only `.git/worktrees/<name>` metadata.
public struct GitWorktreePruneAction: ShellAction {
    public let id = UUID()
    public let repo: URL
    public let staleCount: Int
    public var displayName: String { "\(staleCount) stale worktree\(staleCount == 1 ? "" : "s") in \(repo.lastPathComponent)" }
    public var commandSummary: String { "git -C \(repo.path) worktree prune" }
    public var reversible: Bool { false }
    public var estimatedBytes: Int64 { 0 }

    public init(repo: URL, staleCount: Int) {
        self.repo = repo
        self.staleCount = staleCount
    }

    public func run() -> Shell.Output? {
        guard let git = Shell.find("git") else { return nil }
        return Shell.run(git, ["-C", repo.path, "worktree", "prune"])
    }
}

import Foundation
import Testing
@testable import CoreKit

@Suite("Projects: discovery, git facts, ranking, archive")
struct ProjectScannerTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-proj-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ url: URL, bytes: Int = 64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// Runs git with a fixed identity and an optional backdated commit time.
    @discardableResult
    func git(_ repo: URL, _ args: [String], date: Date? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Shell.find("git") ?? "/usr/bin/git")
        p.arguments = ["-C", repo.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@t"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@t"
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            env["GIT_AUTHOR_DATE"] = stamp; env["GIT_COMMITTER_DATE"] = stamp
        }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    func makeRepo(_ url: URL, committedAt date: Date) throws {
        try write(url.appending(path: "README.md"))
        try git(url, ["init", "-q", "-b", "main"])
        try git(url, ["add", "README.md"])
        try git(url, ["commit", "-q", "-m", "first"], date: date)
        // Backdate the index too, so "last activity" is the commit date.
        for path in [".git/index", "README.md"] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.appending(path: path).path)
        }
    }

    func item(_ url: URL, gb: Double, _ category: CoreKit.Category = .nodeModules) -> ScanItem {
        ScanItem(url: url, sizeBytes: Int64(gb * 1_000_000_000), isDirectory: true, category: category)
    }

    // MARK: Pure parts

    @Test func parsesWorktreeList() {
        let text = """
        worktree /Users/me/app
        HEAD 1111
        branch refs/heads/main

        worktree /Users/me/app-feature
        HEAD 2222
        branch refs/heads/feature/login

        worktree /tmp/gone
        HEAD 3333
        detached
        prunable gitdir file points to non-existent location
        """
        let trees = ProjectScanner.parseWorktrees(text)
        #expect(trees.count == 3)
        #expect(trees[0].isMain && !trees[0].isPrunable && trees[0].branch == "main")
        #expect(trees[1].branch == "feature/login" && !trees[1].isMain)
        #expect(trees[2].isPrunable && trees[2].branch == nil)
    }

    @Test func coldAndBigOutranksFreshAndBig() {
        let now = Date()
        func project(_ days: Double, gb: Double) -> DevProject {
            DevProject(url: URL(fileURLWithPath: "/p/\(days)"), branch: nil, lastCommit: nil, lastCommitSubject: nil,
                       lastActivity: now.addingTimeInterval(-days * 86_400), gitBytes: 0,
                       artifacts: [item(URL(fileURLWithPath: "/p/\(days)/node_modules"), gb: gb)],
                       worktrees: [], isDirty: false, unpushedCommits: nil, containsOtherRepos: false)
        }
        #expect(project(200, gb: 2).score(now: now) > project(1, gb: 4).score(now: now))
        #expect(project(1, gb: 4).score(now: now) > 0)
        #expect(project(400, gb: 1).coldDays(now: now) == 400)
    }

    // MARK: Discovery

    @Test func findsNestedReposAndSkipsBuildDirs() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // The dev root is itself a repo, like a real ~/Developer.
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        for repo in ["app", "tools/cli"] {
            try FileManager.default.createDirectory(at: root.appending(path: "\(repo)/.git"), withIntermediateDirectories: true)
        }
        // A repo inside node_modules must not count.
        try FileManager.default.createDirectory(at: root.appending(path: "app/node_modules/dep/.git"),
                                                withIntermediateDirectories: true)

        let repos = ProjectScanner.findRepos(in: [root]).map(\.path)
        #expect(Set(repos) == [root.path, root.appending(path: "app").path, root.appending(path: "tools/cli").path])

        let owners = ProjectScanner.assign(
            [item(root.appending(path: "app/node_modules"), gb: 1),
             item(root.appending(path: "loose/node_modules"), gb: 1)],
            to: repos.map { URL(fileURLWithPath: $0) })
        #expect(owners[root.appending(path: "app").path]?.count == 1)
        // Outside every sub-repo, so it belongs to the root repo.
        #expect(owners[root.path]?.count == 1)
    }

    // MARK: Real git

    @Test func scanReadsGitFactsAndRanks() async throws {
        guard Shell.find("git") != nil else { return }
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let cold = root.appending(path: "old-site")
        let fresh = root.appending(path: "current-app")
        try makeRepo(cold, committedAt: now.addingTimeInterval(-300 * 86_400))
        try makeRepo(fresh, committedAt: now.addingTimeInterval(-86_400))
        try write(fresh.appending(path: "scratch.txt"))   // untracked -> dirty

        let results = [CategoryResult(category: .nodeModules, items: [
            item(cold.appending(path: "node_modules"), gb: 1),
            item(fresh.appending(path: "node_modules"), gb: 3),
        ])]
        let projects = await ProjectScanner.scan(devRoots: [root], results: results, now: now)
        #expect(projects.map(\.name) == ["old-site", "current-app"])

        let old = try #require(projects.first)
        #expect(old.branch == "main")
        #expect(old.lastCommitSubject == "first")
        #expect(old.coldDays(now: now) >= 299)
        #expect(!old.isDirty)
        #expect(old.unpushedCommits == nil)        // no upstream
        #expect(old.worktrees.count == 1 && old.staleWorktrees.isEmpty)
        #expect(old.gitBytes > 0)
        #expect(projects[1].isDirty)
    }

    @Test func freshEditsCountAsActivityWithoutCommits() async throws {
        guard Shell.find("git") != nil else { return }
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "wip")
        try write(repo.appending(path: "main.py"))
        try git(repo, ["init", "-q"])
        let projects = await ProjectScanner.scan(devRoots: [root], results: [])
        let p = try #require(projects.first)
        #expect(p.lastCommit == nil)
        #expect(p.coldDays() == 0)
    }

    // MARK: Archive

    @Test func archiveLeavesOutBuildOutputAndKeepsSource() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "site")
        try write(project.appending(path: "src/index.js"))
        try write(project.appending(path: "node_modules/react/index.js"), bytes: 4096)
        let out = root.appending(path: "archives")

        let zip = try ProjectArchiver.archive(project, excluding: [project.appending(path: "node_modules")],
                                              into: out, now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(zip.lastPathComponent.hasPrefix("site 2026-"))

        let listing = Shell.run("/usr/bin/unzip", ["-Z1", zip.path])?.stdout ?? ""
        #expect(listing.contains("site/src/index.js"))
        #expect(!listing.contains("node_modules"))
        // Source untouched.
        #expect(FileManager.default.fileExists(atPath: project.appending(path: "node_modules/react/index.js").path))

        // Same day again gets a distinct name, never overwrites.
        let second = try ProjectArchiver.archive(project, excluding: [], into: out,
                                                 now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(second != zip)
    }
}

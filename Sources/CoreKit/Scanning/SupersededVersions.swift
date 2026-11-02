import Foundation

/// Finds installed versions of a tool that its own settings don't select, so
/// they can be listed without touching the one in use. Each tool has its own
/// idea of "current", read from the files the tool itself reads. When that
/// can't be worked out, the tool lists nothing: a guess here breaks someone's
/// toolchain. Read-only.
public enum SupersededVersions {
    public enum Tool: Sendable, Equatable {
        case nvm, rbenv, asdf, java
        case androidBuildTools, androidPlatforms, androidNDK
        case jetBrainsToolbox, claudeCode, hermesTools

        /// Whether project pin files can keep a version of this tool.
        var usesPins: Bool {
            switch self {
            case .nvm, .rbenv, .asdf, .androidBuildTools, .androidPlatforms, .androidNDK: true
            case .java, .jetBrainsToolbox, .claudeCode, .hermesTools: false
            }
        }
    }

    /// An item to list, and its label when the source's own can't say enough.
    typealias Found = (url: URL, detail: String?)

    static let systemJVMRoot = URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")

    static func find(_ tool: Tool, root: URL, home: URL, pins: VersionPins,
                     systemJVMRoot: URL = systemJVMRoot) -> [Found] {
        let urls: [URL]
        switch tool {
        case .nvm: urls = nvm(root: root, home: home, pins: pins)
        case .rbenv: urls = rbenv(root: root, home: home, pins: pins)
        case .asdf: return asdf(root: root, home: home, pins: pins)
        case .java: urls = java(root: root, home: home, systemRoot: systemJVMRoot)
        case .androidBuildTools: urls = android(root: root, keep: pins.androidBuildTools, version: numericName)
        case .androidPlatforms: urls = android(root: root, keep: pins.androidPlatforms, version: platformLevel)
        case .androidNDK: urls = android(root: root, keep: pins.androidNDK, version: numericName)
        case .jetBrainsToolbox: urls = jetBrainsToolbox(root: root)
        case .claudeCode: urls = claudeCode(root: root, home: home)
        case .hermesTools: urls = hermesTools(root: root)
        }
        return urls.map { ($0, nil) }
    }

    // MARK: nvm

    /// Current is `alias/default`. Every alias the user made and every project
    /// pin is kept too. No default, or one set to `system`, lists nothing.
    static func nvm(root: URL, home: URL, pins: VersionPins) -> [URL] {
        let aliases = home.appending(path: ".nvm/alias")
        let installed = realFolders(in: root)
        let names = installed.map(\.lastPathComponent)
        guard let current = nvmResolve("default", installed: names, aliases: aliases) else { return [] }
        var keep: Set<String> = [current]
        // `alias/lts` is nvm's own table of release lines, not a user's choice.
        let userAliases = (try? FileManager.default.contentsOfDirectory(atPath: aliases.path)) ?? []
        for alias in userAliases where alias != "default" && alias != "lts" {
            if let version = nvmResolve(alias, installed: names, aliases: aliases) { keep.insert(version) }
        }
        for pin in pins.node {
            if let version = nvmResolve(pin, installed: names, aliases: aliases) { keep.insert(version) }
        }
        return installed.filter { !keep.contains($0.lastPathComponent) }
    }

    /// The installed folder a spec means, as nvm reads it: an exact or partial
    /// version (the newest match), `node`, or an alias file naming any of these.
    static func nvmResolve(_ spec: String, installed: [String], aliases: URL, depth: Int = 0) -> String? {
        guard depth < 8, let name = firstWord(spec), !name.contains("..") else { return nil }
        if name == "node" || name == "stable" { return newest(installed) }
        let bare = name.hasPrefix("v") ? String(name.dropFirst()) : name
        if bare.first?.isNumber == true {
            let wanted = UpdateChecker.Version(bare).numeric
            guard !wanted.isEmpty else { return nil }
            return newest(installed.filter {
                Array(UpdateChecker.Version($0).numeric.prefix(wanted.count)) == wanted
            })
        }
        guard let text = read(aliases.appending(path: name)) else { return nil }
        return nvmResolve(text, installed: installed, aliases: aliases, depth: depth + 1)
    }

    // MARK: rbenv

    /// Current is `~/.rbenv/version`. rbenv treats a missing file as the system
    /// Ruby, so that and `system` list nothing.
    static func rbenv(root: URL, home: URL, pins: VersionPins) -> [URL] {
        guard let global = read(home.appending(path: ".rbenv/version")).flatMap(firstWord),
              let current = rbenvResolve(global, root: root) else { return [] }
        let keep = Set(pins.ruby.compactMap { rbenvResolve($0, root: root) } + [current])
        return realFolders(in: root).filter { !keep.contains($0.lastPathComponent) }
    }

    /// rbenv accepts a `ruby-` prefix, and plugins add symlinked aliases
    /// (`3.2 -> 3.2.2`), so the link's target is what gets kept.
    static func rbenvResolve(_ spec: String, root: URL) -> String? {
        guard let name = firstWord(spec), !name.contains("/"), !name.contains("..") else { return nil }
        for candidate in [name, name.hasPrefix("ruby-") ? String(name.dropFirst(5)) : name] {
            let url = root.appending(path: candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.resolvingSymlinksInPath().lastPathComponent
            }
        }
        return nil
    }

    // MARK: asdf

    /// Current is what `~/.tool-versions` names for that tool. A tool it
    /// doesn't name, or names only as `system`, lists nothing.
    static func asdf(root: URL, home: URL, pins: VersionPins) -> [Found] {
        let global = parseToolVersions(read(home.appending(path: ".tool-versions")) ?? "")
        return realFolders(in: root).flatMap { tool -> [Found] in
            let name = tool.lastPathComponent
            let current = asdfInstalled(global[name] ?? [], tool: tool)
            guard !current.isEmpty else { return [] }
            let keep = current.union(asdfInstalled(pins.asdf[name] ?? [], tool: tool))
            return realFolders(in: tool)
                .filter { !keep.contains($0.lastPathComponent) }
                .map { ($0, "\(name) version, not in ~/.tool-versions (reinstall needed)") }
        }
    }

    /// Folder names for `.tool-versions` entries, which list fallbacks in
    /// order and store `ref:abc` as `ref-abc`. Aliases resolve to their target.
    private static func asdfInstalled(_ specs: Set<String>, tool: URL) -> Set<String> {
        Set(specs.compactMap { spec in
            guard !spec.contains("/"), !spec.contains("..") else { return nil }
            let url = tool.appending(path: spec.replacingOccurrences(of: ":", with: "-"))
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url.resolvingSymlinksInPath().lastPathComponent
        })
    }

    /// `tool version [fallback…]` per line, `#` starts a comment.
    static func parseToolVersions(_ text: String) -> [String: Set<String>] {
        var tools: [String: Set<String>] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.prefix { $0 != "#" }.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let tool = words.first, words.count >= 2 else { continue }
            tools[tool, default: []].formUnion(words.dropFirst())
        }
        return tools
    }

    // MARK: Java

    /// `java_home` picks the highest version, but a project can ask for any
    /// major and an IDE can bind any JDK, so one default can't make the others
    /// superseded. What can go is an older build of a JDK with a newer build
    /// from the same vendor on the same major, which keeps `java_home`'s pick.
    /// A JDK named in a shell or Gradle config is kept: that's a pinned JAVA_HOME.
    static func java(root: URL, home: URL, systemRoot: URL) -> [URL] {
        let mine = realFolders(in: root).compactMap(JDK.init(bundle:))
        let system = realFolders(in: systemRoot).compactMap(JDK.init(bundle:))
        let configs = [".zshrc", ".zshenv", ".zprofile", ".bash_profile", ".bashrc", ".profile",
                       ".gradle/gradle.properties"]
            .compactMap { read(home.appending(path: $0)) }
        return mine.filter { jdk in
            let newer = (mine + system).contains {
                $0.vendor == jdk.vendor && $0.major == jdk.major && jdk.version < $0.version
            }
            return newer && !configs.contains { $0.contains(jdk.bundle.lastPathComponent) }
        }.map(\.bundle)
    }

    struct JDK {
        let bundle: URL
        let vendor: String
        let major: Int
        let version: UpdateChecker.Version

        /// Nil unless the bundle states its version and vendor: a JDK that
        /// can't be compared is never called older.
        init?(bundle: URL) {
            guard bundle.pathExtension == "jdk",
                  let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let java = plist["JavaVM"] as? [String: Any],
                  let vendor = java["JVMVendor"] as? String,
                  let raw = java["JVMVersion"] as? String else { return nil }
            let version = UpdateChecker.Version(Self.normalized(raw))
            guard let major = version.numeric.first else { return nil }
            self.bundle = bundle
            self.vendor = vendor
            self.major = major
            self.version = version
        }

        /// Java 8 and older call themselves `1.8.0_392`.
        static func normalized(_ raw: String) -> String {
            let dotted = raw.replacingOccurrences(of: "_", with: ".")
            return dotted.hasPrefix("1.") ? String(dotted.dropFirst(2)) : dotted
        }
    }

    // MARK: Android SDK

    /// The SDK has no selected version. Newer build tools and platforms cover
    /// the older ones' jobs unless a project asks for one by number, and Gradle
    /// downloads a missing one itself. So: all but the newest, minus what build
    /// files under the dev roots name. Names that aren't plain versions
    /// (`35.0.0-rc1`, `android-34-ext12`) are neither listed nor compared.
    static func android(root: URL, keep: Set<String>, version: (String) -> UpdateChecker.Version?) -> [URL] {
        let versions = realFolders(in: root)
            .compactMap { url in version(url.lastPathComponent).map { (url: url, version: $0) } }
            .sorted { $0.version < $1.version }
        return versions.dropLast().map(\.url).filter { !keep.contains($0.lastPathComponent) }
    }

    static func numericName(_ name: String) -> UpdateChecker.Version? {
        guard name.first?.isNumber == true, name.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return UpdateChecker.Version(name)
    }

    static func platformLevel(_ name: String) -> UpdateChecker.Version? {
        guard name.hasPrefix("android-") else { return nil }
        let level = name.dropFirst("android-".count)
        return !level.isEmpty && level.allSatisfy(\.isNumber) ? UpdateChecker.Version(String(level)) : nil
    }

    // MARK: JetBrains Toolbox

    /// `apps/<IDE>/ch-<n>/<build>`, kept for rollback. Current is the last
    /// build in the channel's `.history.json`; only older builds are listed.
    /// Toolbox 2 installs into ~/Applications and has no such folders.
    static func jetBrainsToolbox(root: URL) -> [URL] {
        realFolders(in: root).flatMap { app in
            realFolders(in: app).filter { $0.lastPathComponent.hasPrefix("ch-") }.flatMap { channel -> [URL] in
                let builds = realFolders(in: channel).filter { numericName($0.lastPathComponent) != nil }
                guard let current = toolboxCurrentBuild(in: channel),
                      builds.contains(where: { $0.lastPathComponent == current }) else { return [] }
                let currentVersion = UpdateChecker.Version(current)
                return builds.filter { UpdateChecker.Version($0.lastPathComponent) < currentVersion }
            }
        }
    }

    static func toolboxCurrentBuild(in channel: URL) -> String? {
        guard let data = try? Data(contentsOf: channel.appending(path: ".history.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let history = json["history"] as? [[String: Any]],
              let item = history.last?["item"] as? [String: Any] else { return nil }
        return item["build"] as? String
    }

    // MARK: Claude Code

    /// `~/.local/bin/claude` links to the version in use; each version is one
    /// executable file. No such link lists nothing. Also kept: a version with
    /// a lock (a session may be running it), and one hard-linked elsewhere
    /// (ClaudeCode.app shares a version's file, so trashing it frees nothing).
    static func claudeCode(root: URL, home: URL) -> [URL] {
        let link = home.appending(path: ".local/bin/claude")
        guard (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { return [] }
        let target = link.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else { return [] }
        let locks = home.appending(path: ".local/state/claude/locks")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
        return files.filter {
            let name = $0.lastPathComponent
            let values = try? $0.resourceValues(forKeys: keys)
            return values?.isRegularFile == true && values?.isSymbolicLink != true && values?.linkCount == 1
                && AppSupportRules.isVersion(name) && name != target.lastPathComponent
                && !FileManager.default.fileExists(atPath: locks.appending(path: name + ".lock").path)
        }
    }

    // MARK: Hermes

    /// `tools/facts.json` records the version of each package Hermes uses, and
    /// each lives in `<package>-<version>-<platform>`. Only older folders of a
    /// package whose current folder exists are listed.
    static func hermesTools(root: URL) -> [URL] {
        guard let data = try? Data(contentsOf: root.appending(path: "facts.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["packages"] as? [String: [String: Any]] else { return [] }
        let folders = realFolders(in: root)
        return packages.flatMap { package, facts -> [URL] in
            guard let version = facts["version"] as? String else { return [] }
            let prefix = package + "-"
            let current = prefix + version
            guard folders.contains(where: {
                $0.lastPathComponent == current || $0.lastPathComponent.hasPrefix(current + "-")
            }) else { return [] }
            return folders.filter {
                let name = $0.lastPathComponent
                guard name.hasPrefix(prefix) else { return false }
                let rest = String(name.dropFirst(prefix.count))
                return rest.first?.isNumber == true
                    && UpdateChecker.Version(rest) < UpdateChecker.Version(version)
            }
        }
    }

    // MARK: Helpers

    /// Real folders only: a symlink is an alias for something else listed here.
    static func realFolders(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [])
            .filter(AppSupportScanner.isRealDirectory)
    }

    static func newest(_ names: [String]) -> String? {
        names.max { UpdateChecker.Version($0) < UpdateChecker.Version($1) }
    }

    /// Small text files only: these are one-line settings, not documents.
    static func read(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 1 << 20 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The first word of the first line with one, ignoring `#` comments.
    static func firstWord(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            if let word = line.prefix(while: { $0 != "#" }).split(whereSeparator: \.isWhitespace).first {
                return String(word)
            }
        }
        return nil
    }
}

/// Versions projects ask for, so one a project pins isn't called unused. Read
/// from the same files the tools read, a few levels below the dev roots.
struct VersionPins: Sendable {
    var node: Set<String> = []
    var ruby: Set<String> = []
    var asdf: [String: Set<String>] = [:]
    var androidPlatforms: Set<String> = []
    var androidBuildTools: Set<String> = []
    var androidNDK: Set<String> = []

    /// Deep enough for `root/org/project/app/build.gradle`, bounded so a huge
    /// tree costs little.
    static let maxDepth = 3
    static let maxDirectories = 5000
    static let skipDescending: Set<String> = [
        "node_modules", "build", "target", "vendor", "Pods", "DerivedData", "dist", "Library",
    ]

    static func scan(home: URL, devRoots: [URL]) -> VersionPins {
        var pins = VersionPins()
        // A version file in home applies to everything below it.
        pins.read(in: home, names: [".nvmrc", ".node-version", ".ruby-version"])
        var queue: [(url: URL, depth: Int)] = devRoots.map { ($0, 0) }
        var next = 0
        while next < queue.count, next < maxDirectories {
            let (directory, depth) = queue[next]
            next += 1
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            pins.read(in: directory, names: names)
            guard depth < maxDepth else { continue }
            for name in names where !name.hasPrefix(".") && !skipDescending.contains(name) {
                let child = directory.appending(path: name)
                if AppSupportScanner.isRealDirectory(child) { queue.append((child, depth + 1)) }
            }
        }
        return pins
    }

    private mutating func read(in directory: URL, names: [String]) {
        for name in names {
            switch name {
            case ".nvmrc", ".node-version", ".ruby-version":
                guard let text = SupersededVersions.read(directory.appending(path: name)),
                      let word = SupersededVersions.firstWord(text) else { continue }
                if name == ".ruby-version" { ruby.insert(word) } else { node.insert(word) }
            case ".tool-versions":
                guard let text = SupersededVersions.read(directory.appending(path: name)) else { continue }
                asdf.merge(SupersededVersions.parseToolVersions(text)) { $0.union($1) }
            case "build.gradle", "build.gradle.kts":
                guard let text = SupersededVersions.read(directory.appending(path: name)) else { continue }
                readGradle(text)
            default:
                continue
            }
        }
    }

    /// Literal versions only. One from a version catalog can't be read here;
    /// Gradle downloads it again if it's trashed.
    mutating func readGradle(_ text: String) {
        for match in text.matches(of: #/compileSdk(?:Version)?\s*[=( ]\s*"?(?:android-)?(\d+)/#) {
            androidPlatforms.insert("android-\(match.1)")
        }
        for match in text.matches(of: #/buildToolsVersion\s*[=( ]\s*"([\d.]+)"/#) {
            androidBuildTools.insert(String(match.1))
        }
        for match in text.matches(of: #/ndkVersion\s*[=( ]\s*"([\d.]+)"/#) {
            androidNDK.insert(String(match.1))
        }
    }
}

extension CategoryScanner {
    /// Lists every superseded-version source in one pass, since they share the
    /// walk for project pins. Items the policy would refuse are never listed.
    static func supersededItems(_ sources: [CleanSource], home: URL, devRoots: [URL],
                                policy: SafePathPolicy) -> [ScanItem] {
        let present = sources.compactMap { source -> (source: CleanSource, tool: SupersededVersions.Tool, root: URL)? in
            let root = home.appending(path: source.path)
            guard case .superseded(let tool) = source.locate,
                  FileManager.default.fileExists(atPath: root.path) else { return nil }
            return (source, tool, root)
        }
        guard !present.isEmpty else { return [] }
        let pins = present.contains(where: \.tool.usesPins)
            ? VersionPins.scan(home: home, devRoots: devRoots) : VersionPins()
        return present.flatMap { entry in
            SupersededVersions.find(entry.tool, root: entry.root, home: home, pins: pins).compactMap { found in
                guard case .success = policy.classify(found.url) else { return nil }
                let size = DiskScanner.allocatedSize(of: found.url)
                guard size > 0 else { return nil }
                let values = try? found.url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                return ScanItem(url: found.url, sizeBytes: size, isDirectory: values?.isDirectory == true,
                                category: entry.source.category, detail: found.detail ?? entry.source.label,
                                lastModified: values?.contentModificationDate)
            }
        }
    }
}

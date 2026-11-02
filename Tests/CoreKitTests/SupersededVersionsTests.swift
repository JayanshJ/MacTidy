import Foundation
import Testing
@testable import CoreKit

@Suite("Superseded versions and the sources beyond Application Support")
struct SupersededVersionsTests {
    func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "mactidy-versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func write(_ home: URL, _ relative: String, _ text: String = "x") throws {
        let file = home.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    /// Installed versions, as folders with a file so they have a size.
    func install(_ home: URL, _ parent: String, _ versions: [String]) throws {
        for version in versions { try write(home, "\(parent)/\(version)/bin/tool") }
    }

    func names(_ urls: [URL]) -> Set<String> { Set(urls.map(\.lastPathComponent)) }

    func scanner(_ home: URL, devRoots: [URL] = []) -> CategoryScanner {
        CategoryScanner(home: home, devRoots: devRoots, ignore: IgnoreList())
    }

    // MARK: nvm

    func nvm(_ home: URL, pins: VersionPins = VersionPins()) -> Set<String> {
        names(SupersededVersions.nvm(root: home.appending(path: ".nvm/versions/node"), home: home, pins: pins))
    }

    @Test func nvmKeepsExactDefault() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".nvm/versions/node", ["v18.19.0", "v20.11.0", "v22.1.0"])
        try write(home, ".nvm/alias/default", "v20.11.0\n")
        #expect(nvm(home) == ["v18.19.0", "v22.1.0"])
    }

    @Test func nvmPartialDefaultMeansNewestMatch() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".nvm/versions/node", ["v20.9.0", "v20.11.0", "v22.1.0"])
        try write(home, ".nvm/alias/default", "20\n")
        #expect(nvm(home) == ["v20.9.0", "v22.1.0"])
    }

    @Test func nvmFollowsLTSAliasChain() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".nvm/versions/node", ["v20.11.0", "v22.1.0"])
        try write(home, ".nvm/alias/default", "lts/*\n")
        try write(home, ".nvm/alias/lts/*", "lts/iron\n")
        try write(home, ".nvm/alias/lts/iron", "v20.11.0\n")
        #expect(nvm(home) == ["v22.1.0"])
    }

    @Test(arguments: ["system", "iojs", "lts/missing", "v16", "", "# nothing\n"])
    func nvmListsNothingWhenDefaultCantBeResolved(_ value: String) throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".nvm/versions/node", ["v20.11.0", "v22.1.0"])
        try write(home, ".nvm/alias/default", value)
        #expect(nvm(home).isEmpty)
    }

    @Test func nvmListsNothingWithoutADefault() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".nvm/versions/node", ["v20.11.0", "v22.1.0"])
        #expect(nvm(home).isEmpty)
    }

    @Test func nvmAliasCycleEndsInNothing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".nvm/versions/node", ["v20.11.0", "v22.1.0"])
        try write(home, ".nvm/alias/default", "loop")
        try write(home, ".nvm/alias/loop", "default")
        #expect(nvm(home).isEmpty)
    }

    @Test func nvmKeepsUserAliasesAndProjectPins() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".nvm/versions/node", ["v16.20.0", "v18.19.0", "v20.11.0", "v22.1.0"])
        try write(home, ".nvm/alias/default", "v22.1.0")
        try write(home, ".nvm/alias/work", "v18.19.0")
        var pins = VersionPins()
        pins.node = ["20"]
        #expect(nvm(home, pins: pins) == ["v16.20.0"])
    }

    // MARK: rbenv

    func rbenv(_ home: URL, pins: VersionPins = VersionPins()) -> Set<String> {
        names(SupersededVersions.rbenv(root: home.appending(path: ".rbenv/versions"), home: home, pins: pins))
    }

    @Test func rbenvKeepsGlobalAndPins() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".rbenv/versions", ["2.7.8", "3.1.4", "3.2.2"])
        try write(home, ".rbenv/version", "ruby-3.2.2\n")
        var pins = VersionPins()
        pins.ruby = ["3.1.4", "9.9.9"]
        #expect(rbenv(home, pins: pins) == ["2.7.8"])
    }

    @Test func rbenvListsNothingForSystemOrMissingFile() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".rbenv/versions", ["3.1.4", "3.2.2"])
        #expect(rbenv(home).isEmpty)
        try write(home, ".rbenv/version", "system\n")
        #expect(rbenv(home).isEmpty)
        try write(home, ".rbenv/version", "3.0.0\n")
        #expect(rbenv(home).isEmpty)
    }

    @Test func rbenvAliasKeepsItsTargetAndIsNotListed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".rbenv/versions", ["3.1.4", "3.2.2"])
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".rbenv/versions/3.2"),
            withDestinationURL: home.appending(path: ".rbenv/versions/3.2.2"))
        try write(home, ".rbenv/version", "3.2\n")
        #expect(rbenv(home) == ["3.1.4"])
    }

    // MARK: asdf

    @Test func asdfWorksPerToolAndKeepsFallbacksRefsAndPins() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".asdf/installs/nodejs", ["16.0.0", "18.0.0", "20.0.0", "21.0.0"])
        try install(home, ".asdf/installs/ruby", ["3.1.0", "ref-abc"])
        try install(home, ".asdf/installs/python", ["3.11.0", "3.12.0"])
        try install(home, ".asdf/installs/golang", ["1.21.0", "1.22.0"])
        try write(home, ".tool-versions", """
        # global
        nodejs 20.0.0 18.0.0  # with a fallback
        ruby ref:abc
        python system
        """)
        var pins = VersionPins()
        pins.asdf = ["nodejs": ["21.0.0"], "golang": ["1.22.0"]]
        let found = SupersededVersions.asdf(root: home.appending(path: ".asdf/installs"), home: home, pins: pins)
        // python is only `system` and golang isn't named: neither lists anything,
        // even though a pin mentions golang.
        #expect(names(found.map(\.url)) == ["16.0.0", "3.1.0"])
        let node = try #require(found.first { $0.url.lastPathComponent == "16.0.0" })
        #expect(node.detail?.hasPrefix("nodejs version") == true)
    }

    @Test func asdfListsNothingWithoutToolVersions() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".asdf/installs/nodejs", ["18.0.0", "20.0.0"])
        let found = SupersededVersions.asdf(root: home.appending(path: ".asdf/installs"), home: home, pins: VersionPins())
        #expect(found.isEmpty)
    }

    // MARK: Java

    func jdk(_ home: URL, _ root: String, _ name: String, version: String?, vendor: String? = "Temurin") throws {
        var java: [String: String] = [:]
        if let version { java["JVMVersion"] = version }
        if let vendor { java["JVMVendor"] = vendor }
        let data = try PropertyListSerialization.data(fromPropertyList: ["JavaVM": java], format: .xml, options: 0)
        let plist = home.appending(path: "\(root)/\(name).jdk/Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plist)
    }

    static let userJVMs = "Library/Java/JavaVirtualMachines"

    func java(_ home: URL) -> Set<String> {
        names(SupersededVersions.java(root: home.appending(path: Self.userJVMs), home: home,
                                      systemRoot: home.appending(path: "system-jvms")))
    }

    @Test func javaListsOnlyOlderBuildsOfTheSameVendorAndMajor() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try jdk(home, Self.userJVMs, "temurin-17.0.8", version: "17.0.8+7")
        try jdk(home, Self.userJVMs, "temurin-17.0.11", version: "17.0.11+9")
        try jdk(home, Self.userJVMs, "temurin-21.0.1", version: "21.0.1")
        try jdk(home, Self.userJVMs, "corretto-17.0.5", version: "17.0.5", vendor: "Amazon")
        #expect(java(home) == ["temurin-17.0.8.jdk"])
    }

    @Test func javaOrdersOldStyleVersions() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try jdk(home, Self.userJVMs, "temurin-8u382", version: "1.8.0_382")
        try jdk(home, Self.userJVMs, "temurin-8u392", version: "1.8.0_392")
        #expect(java(home) == ["temurin-8u382.jdk"])
    }

    @Test func javaKeepsAJDKNamedInShellConfig() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try jdk(home, Self.userJVMs, "temurin-17.0.8", version: "17.0.8")
        try jdk(home, Self.userJVMs, "temurin-17.0.11", version: "17.0.11")
        try write(home, ".zshrc", "export JAVA_HOME=$HOME/\(Self.userJVMs)/temurin-17.0.8.jdk/Contents/Home\n")
        #expect(java(home).isEmpty)
    }

    @Test func javaCountsSystemJDKsAsNewerButNeverListsThem() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try jdk(home, Self.userJVMs, "temurin-17.0.8", version: "17.0.8")
        try jdk(home, "system-jvms", "temurin-17.0.11", version: "17.0.11")
        try jdk(home, "system-jvms", "temurin-17.0.2", version: "17.0.2")
        #expect(java(home) == ["temurin-17.0.8.jdk"])
    }

    @Test func javaNeverCallsAnUnreadableJDKOlder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try jdk(home, Self.userJVMs, "temurin-17.0.11", version: "17.0.11")
        try jdk(home, Self.userJVMs, "no-version", version: nil)
        try jdk(home, Self.userJVMs, "no-vendor", version: "17.0.1", vendor: nil)
        try write(home, "\(Self.userJVMs)/no-plist.jdk/Contents/Home/bin/java")
        #expect(java(home).isEmpty)
    }

    // MARK: Android SDK

    @Test func androidKeepsNewestAndPinsAndIgnoresOddNames() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, "Library/Android/sdk/build-tools", ["30.0.3", "33.0.2", "34.0.0", "35.0.0-rc1"])
        try install(home, "Library/Android/sdk/platforms", ["android-9", "android-33", "android-34", "android-34-ext12", "android-VanillaIceCream"])
        try install(home, "Library/Android/sdk/ndk", ["25.1.8937393", "26.3.11579264"])
        var pins = VersionPins()
        pins.androidBuildTools = ["33.0.2"]
        pins.androidPlatforms = ["android-33"]

        let sdk = home.appending(path: "Library/Android/sdk")
        func found(_ tool: SupersededVersions.Tool, _ folder: String) -> Set<String> {
            names(SupersededVersions.find(tool, root: sdk.appending(path: folder), home: home, pins: pins).map(\.url))
        }
        #expect(found(.androidBuildTools, "build-tools") == ["30.0.3"])
        // android-9 sorts below android-33 by number, not by text.
        #expect(found(.androidPlatforms, "platforms") == ["android-9"])
        #expect(found(.androidNDK, "ndk") == ["25.1.8937393"])
    }

    @Test func gradleFilesNameWhatProjectsNeed() {
        var pins = VersionPins()
        pins.readGradle("""
        android {
            compileSdk = 34
            compileSdkVersion 33
            compileSdkVersion "android-32"
            compileSdk(31)
            compileSdk = libs.versions.sdk.get().toInt()
            buildToolsVersion "33.0.2"
            ndkVersion = "25.1.8937393"
        }
        """)
        #expect(pins.androidPlatforms == ["android-34", "android-33", "android-32", "android-31"])
        #expect(pins.androidBuildTools == ["33.0.2"])
        #expect(pins.androidNDK == ["25.1.8937393"])
    }

    // MARK: Project pins

    @Test func pinsAreReadBelowDevRootsNotFromSkippedFolders() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".ruby-version", "3.0.0\n")
        try write(home, "code/app/.nvmrc", "18\n")
        try write(home, "code/org/repo/.node-version", "20.1.0\n")
        try write(home, "code/org/repo/app/build.gradle", "compileSdk 33")
        try write(home, "code/org/repo/.tool-versions", "golang 1.21.0\n")
        try write(home, "code/app/node_modules/dep/.nvmrc", "12\n")
        try write(home, "code/.hidden/.nvmrc", "14\n")
        try write(home, "code/a/b/c/d/.nvmrc", "16\n")
        let pins = VersionPins.scan(home: home, devRoots: [home.appending(path: "code")])
        #expect(pins.node == ["18", "20.1.0"])
        #expect(pins.ruby == ["3.0.0"])
        #expect(pins.asdf == ["golang": ["1.21.0"]])
        #expect(pins.androidPlatforms == ["android-33"])
    }

    // MARK: JetBrains Toolbox

    static let toolbox = "Library/Application Support/JetBrains/Toolbox/apps"

    func history(builds: [String]) -> String {
        let items = builds.map { #"{"timestamp":"t","item":{"id":"IDEA","build":"\#($0)"}}"# }
        return #"{"history":[\#(items.joined(separator: ","))]}"#
    }

    @Test func toolboxListsBuildsOlderThanLastInHistory() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let channel = "\(Self.toolbox)/IDEA-U/ch-0"
        try install(home, channel, ["232.1.1", "233.2.2", "241.3.3", "233.2.2.plugins"])
        // The user rolled back: 241 is newer but not current, so it stays.
        try write(home, "\(channel)/.history.json", history(builds: ["232.1.1", "241.3.3", "233.2.2"]))
        let found = SupersededVersions.jetBrainsToolbox(root: home.appending(path: Self.toolbox))
        #expect(names(found) == ["232.1.1"])
    }

    @Test(arguments: [nil, "not json", #"{"history":[]}"#, #"{"history":[{"item":{"build":"999.9"}}]}"#])
    func toolboxListsNothingWithoutAUsableHistory(_ text: String?) throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let channel = "\(Self.toolbox)/IDEA-U/ch-0"
        try install(home, channel, ["232.1.1", "233.2.2"])
        if let text { try write(home, "\(channel)/.history.json", text) }
        #expect(SupersededVersions.jetBrainsToolbox(root: home.appending(path: Self.toolbox)).isEmpty)
    }

    /// Toolbox lives inside Application Support, which has its own category.
    @Test func toolboxBuildsAreNotCountedByApplicationSupport() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let channel = "\(Self.toolbox)/IDEA-U/ch-0"
        let big = String(repeating: "x", count: 2 << 20)
        for build in ["232.1.1", "233.2.2"] { try write(home, "\(channel)/\(build)/lib/idea.jar", big) }
        try write(home, "\(channel)/.history.json", history(builds: ["233.2.2"]))

        let scanner = scanner(home)
        let dev = await scanner.scan(.devCaches).items.map(\.url.lastPathComponent)
        let support = await scanner.scan(.appSupport).items.map(\.url.path)
        #expect(dev == ["232.1.1"])
        #expect(!support.contains { $0.contains("/Toolbox/apps/") })
    }

    // MARK: Claude Code

    func claudeInstall(_ home: URL, current: String) throws {
        for version in ["2.1.310", "2.1.312", "2.1.314"] { try write(home, ".local/share/claude/versions/\(version)") }
        try write(home, ".local/share/claude/ClaudeCode.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: home.appending(path: ".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".local/bin/claude"),
            withDestinationURL: home.appending(path: ".local/share/claude/versions/\(current)"))
    }

    @Test func claudeCodeKeepsTheLinkedVersionAndNeverListsTheInstallWhole() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try claudeInstall(home, current: "2.1.312")
        let scanner = scanner(home)
        let ai = await scanner.scan(.aiAgents).items
        #expect(names(ai.map(\.url)) == ["2.1.310", "2.1.314"])
        #expect(ai.allSatisfy { $0.risk == .caution && !$0.isPreselectable })
        let dev = await scanner.scan(.devCaches).items
        #expect(!dev.contains { $0.url.path.contains("/.local/share/claude") })
    }

    @Test func claudeCodeKeepsLockedAndHardLinkedVersions() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try claudeInstall(home, current: "2.1.314")
        try write(home, ".local/share/claude/versions/2.1.300")
        let versions = home.appending(path: ".local/share/claude/versions")
        // A session is running this one.
        try write(home, ".local/state/claude/locks/2.1.312.lock")
        // The app bundle shares this one's file: trashing it frees nothing.
        try FileManager.default.linkItem(
            at: versions.appending(path: "2.1.310"),
            to: home.appending(path: ".local/share/claude/ClaudeCode.app/Contents/claude"))
        #expect(names(SupersededVersions.claudeCode(root: versions, home: home)) == ["2.1.300"])
    }

    @Test func claudeCodeListsNothingWithoutALink() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, ".local/share/claude", ["x"])
        for version in ["2.1.310", "2.1.312"] { try write(home, ".local/share/claude/versions/\(version)") }
        let ai = await scanner(home).scan(.aiAgents).items
        #expect(ai.isEmpty)
        // A plain file or a link elsewhere is not an answer either.
        try write(home, ".local/bin/claude")
        #expect(SupersededVersions.claudeCode(root: home.appending(path: ".local/share/claude/versions"), home: home).isEmpty)
    }

    // MARK: Hermes

    func hermes(_ home: URL) throws {
        try install(home, ".hermes/tools", [
            "node-26.7.0-darwin-arm64", "node-26.12.1-darwin-arm64",
            "python-3.14.7+20260901-darwin-arm64", "python-3.14.9+20261021-darwin-arm64",
            "npm-12.0.2-darwin-arm64", "chromium-1208", "chromium-1100",
        ])
    }

    @Test func hermesListsOnlyOlderFoldersOfPackagesItCanPlace() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try hermes(home)
        try write(home, ".hermes/tools/facts.json", """
        {"packages":{"node":{"version":"26.12.1"},"python":{"version":"3.14.9+20261021"},
         "npm":{"version":"12.0.2"},"chromium":{"version":"1208+145.0.7632.6"},"missing":{}},"schema":1}
        """)
        let found = SupersededVersions.hermesTools(root: home.appending(path: ".hermes/tools"))
        // chromium's folder doesn't carry its full version, so it stays.
        #expect(names(found) == ["node-26.7.0-darwin-arm64", "python-3.14.7+20260901-darwin-arm64"])
    }

    @Test func hermesListsNothingWithoutFacts() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try hermes(home)
        #expect(SupersededVersions.hermesTools(root: home.appending(path: ".hermes/tools")).isEmpty)
    }

    @Test func hermesDataIsNeverListed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".hermes/.env", "KEY=1")
        try write(home, ".hermes/auth.json", "{}")
        try write(home, ".hermes/memories/a.md")
        try write(home, ".hermes/sessions/s.json")
        try write(home, ".hermes/hermes-agent/run.py")
        try write(home, ".hermes/installs/abc/environments/venv/python")
        try write(home, ".hermes/cache/uv/wheels/x.whl")
        try write(home, ".hermes/cache/model_catalog.json", "{}")
        let ai = await scanner(home).scan(.aiAgents).items
        #expect(ai.map(\.url.lastPathComponent) == ["uv"])
        #expect(ai.first?.risk == .safe)
    }

    // MARK: Risk

    @Test func everySupersededSourceIsCaution() {
        let superseded = CleanSource.all.filter { if case .superseded = $0.locate { true } else { false } }
        #expect(superseded.count == 10)
        for source in superseded { #expect(source.risk == .caution, "\(source.path)") }
    }

    @Test func nestedVersionsTakeTheirSourcesRisk() {
        let base = URL(fileURLWithPath: "/tmp/h")
        for path in [".asdf/installs/nodejs/18.0.0", ".nvm/versions/node/v18.0.0",
                     "Library/Application Support/JetBrains/Toolbox/apps/IDEA-U/ch-0/232.1.1"] {
            let item = ScanItem(url: base.appending(path: path), sizeBytes: 1, isDirectory: true, category: .devCaches)
            #expect(item.risk == .caution, "\(path)")
            #expect(!item.isPreselectable, "\(path)")
        }
    }

    /// The test in CleanSourceTests checks a path below each source. A source
    /// listed whole is trashed at its own path, so that has to pass too:
    /// a secret added inside one would otherwise make its row a dead end.
    @Test func everyWholeSourceItselfIsTrashable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let policy = SafePathPolicy(home: home)
        for source in CleanSource.all where source.locate == .whole {
            if case .failure(let v) = policy.classify(home.appending(path: source.path)) {
                Issue.record("\(source.path): \(v)")
            }
        }
    }

    @Test func uiTextHasNoEmDashes() {
        for source in CleanSource.all { #expect(!source.label.contains("\u{2014}"), "\(source.path)") }
    }

    // MARK: New sources

    /// One file per folder this category claims, with secrets and hand-made
    /// things beside them that must not be listed.
    @Test func newSourcesListTheirCachesAndLeaveTheirNeighbours() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [
            "Library/iTunes/iPhone Software Updates/iPhone_17.ipsw",
            "Library/Developer/Xcode/DocumentationCache/v1/doc",
            "Library/Developer/XCTestDevices/ABC/data",
            "Library/Developer/XCPGDevices/ABC/data",
            ".nuget/packages/newtonsoft/13.0/x.nupkg",
            ".ivy2/cache/org/a.jar",
            ".gem/specs/index",
            ".hex/packages/hexpm/x.tar",
            ".stack/pantry/index",
            ".opam/download-cache/x",
            ".vscode-server/bin/abc/node",
            ".cursor-server/cli/servers/Stable-abc/server",
        ] { try write(home, path) }
        for path in [
            ".gem/credentials", ".nuget/NuGet/NuGet.Config", ".ivy2/.credentials", ".ivy2/local/mine.jar",
            ".cabal/config", ".cabal/bin/tool", ".stack/config.yaml", ".hex/hex.config", ".opam/config",
            ".opam/default/bin/ocaml", ".mix/escripts/tool", ".vscode-server/data/Machine/settings.json",
            ".swiftpm/configuration/mirrors.json",
        ] { try write(home, path) }

        let dev = await scanner(home).scan(.devCaches).items
        // Listings say /private/var where the fake home says /var, so cut at its name.
        let listed = Set(dev.map { $0.url.path.components(separatedBy: home.lastPathComponent + "/").last ?? "" })
        #expect(listed == [
            "Library/iTunes/iPhone Software Updates/iPhone_17.ipsw",
            "Library/Developer/Xcode/DocumentationCache", "Library/Developer/XCTestDevices",
            "Library/Developer/XCPGDevices", ".nuget/packages", ".ivy2/cache", ".gem/specs",
            ".hex/packages", ".stack/pantry", ".opam/download-cache", ".vscode-server/bin",
            ".cursor-server/cli/servers",
        ])
        #expect(dev.allSatisfy { $0.risk == .safe })
    }

    @Test func installedThingsAreCaution() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [
            ".gem/ruby/3.2.0/gems/x", ".stack/programs/ghc", ".stack/snapshots/x", ".cabal/packages/x",
            ".cabal/store/x", ".mix/archives/hex", ".julia/artifacts/abc/lib", ".docker/buildx/instances/x",
            ".vscode-server/extensions/x/y", ".cursor-server/extensions/x/y",
        ] { try write(home, path) }
        let dev = await scanner(home).scan(.devCaches).items
        #expect(dev.count == 10)
        #expect(dev.allSatisfy { $0.risk == .caution && !$0.isPreselectable })
    }

    /// `~/.swiftpm/cache` is a link to Library/Caches/org.swift.swiftpm on
    /// current toolchains. The walker follows a root symlink, so without care
    /// the same bytes would be listed twice under one ID.
    @Test func symlinkedSwiftPMCacheIsListedOnce() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, "Library/Caches/org.swift.swiftpm/manifests/x")
        try FileManager.default.createDirectory(at: home.appending(path: ".swiftpm"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".swiftpm/cache"),
            withDestinationURL: home.appending(path: "Library/Caches/org.swift.swiftpm"))
        let dev = await scanner(home).scan(.devCaches).items
        #expect(dev.map(\.url.lastPathComponent) == ["org.swift.swiftpm"])
    }

    @Test func oldToolchainSwiftPMCacheIsListed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".swiftpm/cache/repositories/x")
        let dev = await scanner(home).scan(.devCaches).items
        #expect(dev.map(\.url.lastPathComponent) == ["cache"])
        #expect(dev.first?.risk == .safe)
    }

    // MARK: ~/.local/share

    @Test func localShareChildrenAreCautionAndNamedOnesListedOnce() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".local/share/nvim/site/plugin.lua")
        try write(home, ".local/share/.DS_Store")
        try write(home, ".local/share/uv/python/.lock")
        try write(home, ".local/share/uv/python/.gitignore")
        try write(home, ".local/share/uv/python/cpython-3.12.1/bin/python")
        try write(home, ".local/share/uv/tools/ruff/bin/ruff")
        try write(home, ".local/share/pnpm/store/v3/x")
        try write(home, ".local/share/virtualenvs/app-abc/bin/python")
        try write(home, ".local/share/Trash/files/x")
        try write(home, ".local/share/containers/podman/machine/disk.raw")
        // A secret inside a child: the child can't be trashed, so it isn't a row.
        try write(home, ".local/share/opencode/auth.json", "{}")
        try write(home, ".local/share/opencode/log/x")

        let dev = await scanner(home).scan(.devCaches).items
        func risk(_ name: String) -> Risk? { dev.first { $0.url.lastPathComponent == name }?.risk }
        #expect(names(dev.map(\.url)) == [
            "nvim", "cpython-3.12.1", "ruff", "store", "app-abc", "Trash", "containers",
        ])
        #expect(risk("nvim") == .caution)
        #expect(risk("cpython-3.12.1") == .caution)
        #expect(risk("ruff") == .caution)
        #expect(risk("store") == .safe)
        #expect(risk("Trash") == .caution)
        #expect(risk("containers") == .danger)

        // No byte is claimed twice: nothing listed sits inside anything else listed.
        let paths = dev.map(\.url.path)
        for path in paths { #expect(!paths.contains { path.hasPrefix($0 + "/") }, "\(path)") }
    }

    // MARK: Credentials

    @Test(arguments: [
        ".gem/credentials", ".nuget/NuGet/NuGet.Config", ".ivy2/.credentials", ".cabal/config",
        ".stack/config.yaml", ".stack/upload/credentials.json", ".hex/hex.config",
        ".lmstudio/credentials/ng-mcp-oauth/x", ".hermes/.env", ".hermes/auth.json",
        ".hermes/config.yaml", ".hermes/pairing/x", ".hermes/backups/config/a",
        ".agent-reach/state.json", ".agent-reach/config.yaml", ".local/share/opencode/auth.json",
        ".local/share/atuin/key", ".local/share/keyrings/login.keyring",
        ".sbt/.credentials", ".fastlane/spaceship/me@example.com/cookie", ".pub-cache/credentials.json",
        // Ancestors: the folder can't be trashed with the secret inside.
        ".gem", ".nuget", ".ivy2", ".cabal", ".stack", ".hex", ".lmstudio", ".hermes",
        ".agent-reach", ".local", ".local/share", ".local/share/opencode",
        ".sbt", ".fastlane", ".pub-cache",
    ])
    func newCredentialsAndTheirFoldersAreDenied(_ relative: String) throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let policy = SafePathPolicy(home: home)
        guard case .failure(.credentialPath) = policy.classify(home.appending(path: relative)) else {
            Issue.record("\(relative) was not denied as a credential path"); return
        }
    }

    @Test func newSourcesBesideSecretsStayTrashable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let policy = SafePathPolicy(home: home)
        for relative in [".gem/specs", ".lmstudio/hub", ".lmstudio/extensions", ".hermes/cache/uv",
                         ".hermes/tools/node-26.7.0-darwin-arm64", ".agent-reach/tools/ffmpeg",
                         ".local/share/nvim", ".local/share/claude/versions/2.1.310"] {
            if case .failure(let v) = policy.classify(home.appending(path: relative)) {
                Issue.record("\(relative): \(v)")
            }
        }
    }

    // MARK: Running apps

    @Test func openAppsWarnAboutTheFoldersTheyUse() {
        let home = URL(fileURLWithPath: "/tmp/h")
        let xcode = RunningAppGuard.conflicts(for: [home.appending(path: "Library/Developer/XCTestDevices")],
                                              runningBundleIDs: ["com.apple.dt.Xcode"], home: home)
        #expect(xcode.map(\.appName) == ["Xcode"])
        let studio = RunningAppGuard.conflicts(for: [home.appending(path: "Library/Android/sdk/ndk/25.1.8937393")],
                                               runningBundleIDs: ["com.google.android.studio"], home: home)
        #expect(studio.map(\.appName) == ["Android Studio"])
    }
}

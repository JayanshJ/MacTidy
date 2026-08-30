import Foundation
import Testing
@testable import CoreKit

/// `PortScanner` parsing + `DevRuntime` classification. Tests exercise the
/// pure helpers (`parsePsLookup`, `attributeAppBundle`, `DevRuntime.classify`)
/// without shelling out. Mirrors `DockerScannerTests`'s fixture-based approach.
@Suite("PortScanner")
struct PortScannerTests {
    // MARK: - parsePsLookup (ps -p ... -o pid=,comm= parser)

    @Test func parsePsLookupMapsPIDToComm() {
        let stdout = """
         4521 /usr/local/bin/node
         8302 /usr/bin/python3
        15691 /Applications/Docker.app/Contents/MacOS/com.docker.backend
        """
        let map = PortScanner.parsePsLookup(stdout)
        #expect(map[4521] == "/usr/local/bin/node")
        #expect(map[8302] == "/usr/bin/python3")
        #expect(map[15691] == "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
    }

    @Test func parsePsLookupHandlesEmptyOutput() {
        #expect(PortScanner.parsePsLookup("").isEmpty)
    }

    @Test func parsePsLookupSkipsMalformedLines() {
        let stdout = """
        garbage line with no pid
        123
        456 valid comm
        """
        let map = PortScanner.parsePsLookup(stdout)
        #expect(map.count == 1)
        #expect(map[456] == "valid comm")
    }

    // MARK: - attributeAppBundle (.app rollup)

    @Test func attributeAppBundleExtractsDocker() {
        let comm = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
        #expect(PortScanner.attributeAppBundle(comm) == "Docker")
    }

    @Test func attributeAppBundleExtractsSpotify() {
        let comm = "/Applications/Spotify.app/Contents/MacOS/Spotify"
        #expect(PortScanner.attributeAppBundle(comm) == "Spotify")
    }

    @Test func attributeAppBundleReturnsNilForNonApp() {
        #expect(PortScanner.attributeAppBundle("/usr/local/bin/node") == nil)
        #expect(PortScanner.attributeAppBundle("rapportd") == nil)
    }

    // MARK: - DevRuntime classification

    @Test func classifyNodeVariants() {
        #expect(DevRuntime.classify("node") == .node)
        #expect(DevRuntime.classify("/usr/local/bin/npx") == .node)
        #expect(DevRuntime.classify("npm") == .node)
        #expect(DevRuntime.classify("tsx") == .node)
        #expect(DevRuntime.classify("deno") == .node)
    }

    @Test func classifyPythonVariants() {
        #expect(DevRuntime.classify("python") == .python)
        #expect(DevRuntime.classify("python3.12") == .python)
        #expect(DevRuntime.classify("uvicorn") == .python)
        #expect(DevRuntime.classify("gunicorn") == .python)
    }

    @Test func classifyJavaVariants() {
        #expect(DevRuntime.classify("java") == .java)
        #expect(DevRuntime.classify("gradle") == .java)
        #expect(DevRuntime.classify("kotlin") == .java)
        #expect(DevRuntime.classify("sbt") == .java)
    }

    @Test func classifyRubyVariants() {
        #expect(DevRuntime.classify("ruby") == .ruby)
        #expect(DevRuntime.classify("rails") == .ruby)
        #expect(DevRuntime.classify("puma") == .ruby)
    }

    @Test func classifyGoVariants() {
        #expect(DevRuntime.classify("go") == .go)
        #expect(DevRuntime.classify("air") == .go)
    }

    @Test func classifyDockerVariants() {
        #expect(DevRuntime.classify("Docker") == .docker)
        #expect(DevRuntime.classify("com.docker.backend") == .docker)
        #expect(DevRuntime.classify("com.docke") == .docker)
    }

    @Test func classifyDatabaseVariants() {
        #expect(DevRuntime.classify("postgres") == .database)
        #expect(DevRuntime.classify("redis-server") == .database)
        #expect(DevRuntime.classify("mysqld") == .database)
        #expect(DevRuntime.classify("mongod") == .database)
    }

    @Test func classifyUnknownIsOther() {
        #expect(DevRuntime.classify("rapportd") == .other)
        #expect(DevRuntime.classify("ControlCe") == .other)
        #expect(DevRuntime.classify("Spotify") == .other)
    }

    @Test func classifyTwoArgPrefersProcessName() {
        // When ps says "Docker" (attributed .app name) but lsof says "com.docke"
        // (truncated), the attributed name wins and both classify as .docker.
        let r = DevRuntime.classify(processName: "Docker", lsofCommand: "com.docke")
        #expect(r == .docker)
    }

    @Test func classifyTwoArgFallsBackToLsofCommand() {
        // If the process name is unrecognized but lsof shows "com.docker.backend",
        // the lsof fallback should catch it.
        let r = DevRuntime.classify(processName: "unknown-proc", lsofCommand: "com.docker.backend")
        #expect(r == .docker)
    }

    @Test func classifyTwoArgWithFullCommPath() {
        // ps returns the full path; classify should extract the last component.
        let r = DevRuntime.classify(
            processName: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
            lsofCommand: "com.docke"
        )
        #expect(r == .docker)
    }

    // MARK: - PortExplanation (plain-language glossary)

    @Test func explainRapportd() {
        let r = PortEntry(pid: 974, port: 53185, processName: "rapportd",
                          lsofCommand: "rapportd", devRuntime: .other, bindAddress: "*")
        #expect(r.explanation.contains("Apple"))
        #expect(r.explanation.contains("Continuity"))
    }

    @Test func explainControlCenter() {
        let r = PortEntry(pid: 1305, port: 5000, processName: "ControlCe",
                          lsofCommand: "ControlCe", devRuntime: .other, bindAddress: "*")
        #expect(r.explanation.contains("Control Center"))
    }

    @Test func explainDockerPort() {
        let r = PortEntry(pid: 15691, port: 8080, processName: "Docker",
                          lsofCommand: "com.docke", devRuntime: .docker, bindAddress: "127.0.0.1")
        #expect(r.explanation.contains("Docker"))
        #expect(r.explanation.contains("container"))
    }

    @Test func explainSpotify() {
        let r = PortEntry(pid: 1549, port: 57621, processName: "Spotify",
                          lsofCommand: "Spotify", devRuntime: .other, bindAddress: "*")
        #expect(r.explanation.contains("Spotify"))
    }

    @Test func explainNodeDevServer() {
        let r = PortEntry(pid: 4521, port: 3000, processName: "node",
                          lsofCommand: "node", devRuntime: .node, bindAddress: "*")
        #expect(r.explanation.contains("Node.js"))
        #expect(r.explanation.contains("dev server"))
    }

    @Test func explainPythonFallback() {
        let r = PortEntry(pid: 8302, port: 8000, processName: "python3",
                          lsofCommand: "python3", devRuntime: .python, bindAddress: "127.0.0.1")
        #expect(r.explanation.contains("Python"))
        #expect(r.explanation.contains("Django") || r.explanation.contains("Flask"))
    }

    @Test func explainDatabaseFallback() {
        let r = PortEntry(pid: 12345, port: 5432, processName: "postgres",
                          lsofCommand: "postgres", devRuntime: .database, bindAddress: "127.0.0.1")
        #expect(r.explanation.contains("database"))
    }

    @Test func explainSystemPathInference() {
        // A system process that's NOT in the curated glossary — should fall
        // through to the path-based heuristic.
        let r = PortEntry(pid: 200, port: 7000,
                          processName: "/System/Library/PrivateFrameworks/SomeFramework.framework/somed",
                          lsofCommand: "somed", devRuntime: .other, bindAddress: "*")
        #expect(r.explanation.contains("system process"))
    }

    @Test func explainHomebrewPathInference() {
        let r = PortEntry(pid: 300, port: 9000,
                          processName: "/opt/homebrew/bin/some-server",
                          lsofCommand: "some-serv", devRuntime: .other, bindAddress: "*")
        #expect(r.explanation.contains("Homebrew"))
    }

    @Test func explainEmptyForTrulyUnknown() {
        // A name that's not in the glossary, not a recognizable path, and
        // runtime is .other → the fallback returns empty.
        let r = PortEntry(pid: 999, port: 12345, processName: "zzzunknown",
                          lsofCommand: "zzzunknown", devRuntime: .other, bindAddress: "*")
        #expect(r.explanation.isEmpty)
    }
}
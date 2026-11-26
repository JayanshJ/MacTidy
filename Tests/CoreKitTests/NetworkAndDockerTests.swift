import Foundation
import Testing
@testable import CoreKit

@Suite("NetworkScanner and Docker Toolkit Upgrades")
struct NetworkAndDockerTests {
    @Test func parsesDefaultRoute() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.0.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        let parsed = NetworkScanner.parseRouteDefault(output)
        #expect(parsed.interface == "en0")
        #expect(parsed.gateway == "192.168.0.1")
    }

    @Test func parsesScutilDNSSkippingUnreachableResolvers() {
        let output = """
        DNS configuration

        resolver #1
          nameserver[0] : 100.100.100.100
          nameserver[1] : fd7a:115c:a1e0::53
          reach    : 0x00000003 (Reachable,Transient Connection)

        resolver #2
          nameserver[0] : 192.168.0.1
          nameserver[1] : 100.100.100.100
          reach    : 0x00020002 (Reachable,Directly Reachable Address)

        resolver #3
          domain   : local
          nameserver[0] : 10.0.0.53
          reach    : 0x00000000 (Not Reachable)
        """
        let servers = NetworkScanner.parseScutilDNS(output)
        #expect(servers == ["100.100.100.100", "fd7a:115c:a1e0::53", "192.168.0.1"])
    }

    @Test func parsesLsofEstablishedConnections() {
        let output = """
        p100
        cnode
        f12
        n127.0.0.1:5173->127.0.0.1:54321
        f13
        n127.0.0.1:5173->127.0.0.1:54321
        p200
        cpostgres
        f8
        n192.168.0.5:59100->10.0.0.10:5432
        """
        let conns = NetworkScanner.parseEstablishedConnections(output)
        #expect(conns.count == 2)
        #expect(conns[0].pid == 100)
        #expect(conns[0].processName == "node")
        #expect(conns[0].remoteEndpoint == "127.0.0.1:54321")
        #expect(conns[1].pid == 200)
        #expect(conns[1].processName == "postgres")
    }

    @Test func flushDNSActionSummaryIsTransparent() {
        let action = FlushDNSCacheAction()
        #expect(action.reversible == false)
        #expect(action.commandSummary.contains("dscacheutil -flushcache"))
        #expect(action.commandSummary.contains("mDNSResponder"))
    }

    @Test func parsesBatchedDockerInspect() {
        let raw = """
        sha256:aaa\tweb-app
        sha256:bbb\t
        8cc8da1aa787119\t/app|/Users/demo/project,
        """
        let map = DockerScanner.parseBatchedInspect(raw)
        #expect(map["sha256:aaa"] == "web-app")
        #expect(map["sha256:bbb"] == "")
        #expect(map["8cc8da1aa787119"] == "/app|/Users/demo/project,")
    }

    @Test func parsesDockerVolumesFromSystemDF() {
        let df = """
        Images space usage:
        REPOSITORY   TAG   IMAGE ID   CREATED   SIZE   SHARED SIZE   UNIQUE SIZE   CONTAINERS

        Local Volumes space usage:

        VOLUME NAME                        LINKS     SIZE
        worldstate-local_pgdata            1         91.93MB
        orphan_cache_vol                   0         1.5GB

        Build cache usage: 3.355GB
        """
        let vols = DockerScanner.parseVolumesFromSystemDF(df)
        #expect(vols.count == 2)
        #expect(vols[0].name == "orphan_cache_vol")
        #expect(vols[0].inUse == false)
        #expect(vols[0].sizeBytes == 1_500_000_000)
        #expect(vols[1].name == "worldstate-local_pgdata")
        #expect(vols[1].inUse == true)
        #expect(vols[1].links == 1)
    }

    @Test func parsesDockerContexts() {
        let raw = """
        default\tfalse\tunix:///var/run/docker.sock
        desktop-linux\ttrue\tunix:///Users/demo/.docker/run/docker.sock
        """
        let contexts = DockerScanner.parseContexts(raw)
        #expect(contexts.count == 2)
        #expect(contexts[0].isCurrent == false)
        #expect(contexts[1].name == "desktop-linux")
        #expect(contexts[1].isCurrent == true)
    }

    @Test func dockerVolumeRemoveActionSummary() {
        let vol = DockerVolume(name: "orphan_vol", links: 0, sizeBytes: 512_000_000)
        let action = DockerVolumeRemoveAction(volume: vol)
        #expect(action.commandSummary == "docker volume rm orphan_vol")
        #expect(action.reversible == false)
        #expect(action.estimatedBytes == 512_000_000)
    }
}

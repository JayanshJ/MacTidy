import Foundation
import Darwin

public struct NetworkInterfaceInfo: Identifiable, Sendable, Equatable {
    public let name: String
    public let address: String
    public let isPrimary: Bool
    public var id: String { "\(name):\(address)" }

    public init(name: String, address: String, isPrimary: Bool = false) {
        self.name = name
        self.address = address
        self.isPrimary = isPrimary
    }
}

public struct NetworkConnection: Identifiable, Sendable, Equatable {
    public let pid: Int32
    public let processName: String
    public let localEndpoint: String
    public let remoteEndpoint: String
    public var id: String { "\(pid):\(localEndpoint)->\(remoteEndpoint)" }

    public init(pid: Int32, processName: String, localEndpoint: String, remoteEndpoint: String) {
        self.pid = pid
        self.processName = processName
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
    }
}

public struct NetworkSnapshot: Sendable, Equatable {
    public let interfaces: [NetworkInterfaceInfo]
    public let defaultInterface: String?
    public let gateway: String?
    public let dnsServers: [String]
    public let connections: [NetworkConnection]

    public init(
        interfaces: [NetworkInterfaceInfo],
        defaultInterface: String?,
        gateway: String?,
        dnsServers: [String],
        connections: [NetworkConnection]
    ) {
        self.interfaces = interfaces
        self.defaultInterface = defaultInterface
        self.gateway = gateway
        self.dnsServers = dnsServers
        self.connections = connections
    }
}

/// Read-only network diagnostics: active IPv4 interfaces, default gateway,
/// configured DNS servers, and established TCP connections.
public enum NetworkScanner {
    public static func scan() -> NetworkSnapshot {
        let routeOut = Shell.run("/sbin/route", ["-n", "get", "default"])?.stdout ?? ""
        let route = parseRouteDefault(routeOut)
        let interfaces = activeIPv4Interfaces(primaryInterface: route.interface)
        let dnsOut = Shell.run("/usr/sbin/scutil", ["--dns"])?.stdout ?? ""
        let dnsServers = parseScutilDNS(dnsOut)
        let lsofOut = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-F", "pcn"])?.stdout ?? ""
        let connections = parseEstablishedConnections(lsofOut)
        return NetworkSnapshot(
            interfaces: interfaces,
            defaultInterface: route.interface,
            gateway: route.gateway,
            dnsServers: dnsServers,
            connections: connections
        )
    }

    public static func activeIPv4Interfaces(primaryInterface: String?) -> [NetworkInterfaceInfo] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(first) }

        var results: [NetworkInterfaceInfo] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, !isLoopback,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let err = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard err == 0 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            let ip = String(decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            results.append(NetworkInterfaceInfo(
                name: name,
                address: ip,
                isPrimary: name == primaryInterface
            ))
        }
        return results.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            return $0.name < $1.name
        }
    }

    public static func parseRouteDefault(_ stdout: String) -> (interface: String?, gateway: String?) {
        var iface: String?
        var gateway: String?
        for raw in stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("interface:") {
                iface = line.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("gateway:") {
                gateway = line.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return (iface, gateway)
    }

    /// Extracts deduplicated nameserver IPs from `scutil --dns`, skipping
    /// unreachable resolvers (such as disabled mDNS entries).
    public static func parseScutilDNS(_ stdout: String) -> [String] {
        var seen = Set<String>()
        var servers: [String] = []
        var blockServers: [String] = []
        var blockReachable = true

        func flushBlock() {
            guard blockReachable else {
                blockServers.removeAll()
                return
            }
            for s in blockServers where seen.insert(s).inserted {
                servers.append(s)
            }
            blockServers.removeAll()
        }

        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") {
                flushBlock()
                blockReachable = true
            } else if line.hasPrefix("nameserver[") {
                if let colon = line.firstIndex(of: ":") {
                    let ip = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !ip.isEmpty { blockServers.append(ip) }
                }
            } else if line.hasPrefix("reach") && line.contains("Not Reachable") {
                blockReachable = false
            }
        }
        flushBlock()
        return servers
    }

    /// Parses `lsof -nP -iTCP -sTCP:ESTABLISHED -F pcn` output.
    public static func parseEstablishedConnections(_ stdout: String) -> [NetworkConnection] {
        var currentPID: Int32?
        var currentCommand = ""
        var seen = Set<String>()
        var results: [NetworkConnection] = []

        for raw in stdout.split(separator: "\n") {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p":
                currentPID = Int32(value)
                currentCommand = ""
            case "c":
                currentCommand = value
            case "n":
                guard let pid = currentPID, !currentCommand.isEmpty,
                      let arrow = value.range(of: "->") else { continue }
                let local = String(value[..<arrow.lowerBound])
                let remote = String(value[arrow.upperBound...])
                let conn = NetworkConnection(
                    pid: pid,
                    processName: currentCommand,
                    localEndpoint: local,
                    remoteEndpoint: remote
                )
                if seen.insert(conn.id).inserted {
                    results.append(conn)
                }
            default:
                break
            }
        }
        return results
    }
}

import Foundation

/// Session-only activity. Unknown apps must be observed for five minutes;
/// CPU-quiet does not establish that an app is idle.
public struct AppActivity: Sendable {
    public private(set) var frontmostPath: String?
    private var lastUsed: [String: Date] = [:]
    private var firstSeen: [String: Date] = [:]

    public init() {}

    public mutating func observe(paths: [String], frontmost: String?, launchDates: [String: Date] = [:], now: Date = Date()) {
        let running = Set(paths)
        firstSeen = firstSeen.filter { running.contains($0.key) }
        lastUsed = lastUsed.filter { running.contains($0.key) }
        for path in paths {
            if firstSeen[path] == nil { firstSeen[path] = now }
            if let launch = launchDates[path], let seen = firstSeen[path], launch > seen {
                firstSeen[path] = now
                lastUsed[path] = nil
            }
        }
        if let previous = frontmostPath { lastUsed[previous] = now }
        frontmostPath = frontmost
        if let frontmost { lastUsed[frontmost] = now }
    }

    public func idleSeconds(for path: String, now: Date = Date()) -> Double {
        guard path != frontmostPath, let since = lastUsed[path] ?? firstSeen[path] else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }
}

public struct RunningAppMemory: Identifiable, Sendable {
    public let path: String
    public let name: String
    public let processes: [RunningProcess]
    public var id: String { path }
    /// Unknown if any helper could not be measured. Never substitute summed RSS.
    public var footprintBytes: Int64? {
        guard processes.allSatisfy({ $0.physicalFootprintBytes != nil }) else { return nil }
        return processes.reduce(0) { $0 + ($1.physicalFootprintBytes ?? 0) }
    }
    public var isSafeToQuit: Bool {
        !path.hasPrefix("/System/") && processes.allSatisfy(\.isSafeToQuit)
            && processes.reduce(0) { $0 + $1.cpuPercent } < ProcessScanner.idleCpuThreshold
    }

    public static func grouped(_ processes: [RunningProcess]) -> [Self] {
        Dictionary(grouping: processes.filter { $0.appBundlePath != nil }) { $0.appBundlePath! }
            .map { path, processes in
                Self(path: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                     processes: processes)
            }
            .sorted { ($0.footprintBytes ?? 0) > ($1.footprintBytes ?? 0) }
    }
}

public enum MemoryAdvice {
    public static func isUseful(pressure: MemoryPressureLevel?, swapBytes: Int64) -> Bool {
        (pressure.map { $0 >= .warning } ?? false) || swapBytes >= 1_073_741_824
    }

    public static func candidates(processes: [RunningProcess], pressure: MemoryPressureLevel?,
                                  swapBytes: Int64) -> [RunningAppMemory] {
        guard isUseful(pressure: pressure, swapBytes: swapBytes) else { return [] }
        return RunningAppMemory.grouped(processes).filter {
            $0.isSafeToQuit && ($0.footprintBytes ?? 0) >= 200 * 1024 * 1024
        }
    }
}

/// Bounded session history: growth is evidence for a possible leak, not a diagnosis.
public struct AppMemoryHistory: Sendable {
    public struct Sample: Sendable {
        public let date: Date
        public let bytes: Int64
        public let mainPID: Int32
    }
    private var samples: [String: [Sample]] = [:]
    public init() {}

    public mutating func record(_ apps: [RunningAppMemory], now: Date = Date()) {
        let paths = Set(apps.map(\.path))
        samples = samples.filter { paths.contains($0.key) }
        for app in apps {
            guard let bytes = app.footprintBytes, let pid = app.processes.map(\.pid).min() else {
                samples[app.path] = nil
                continue
            }
            var history = samples[app.path] ?? []
            if history.last?.mainPID != pid { history = [] }
            history.removeAll { now.timeIntervalSince($0.date) > 4 * 3600 }
            if history.last.map({ now.timeIntervalSince($0.date) >= 60 }) ?? true {
                history.append(Sample(date: now, bytes: bytes, mainPID: pid))
            }
            samples[app.path] = Array(history.suffix(241))
        }
    }

    public func growth(for path: String) -> Int64? {
        guard let history = samples[path], history.count >= 4,
              let first = history.first, let last = history.last,
              last.date.timeIntervalSince(first.date) >= 2 * 3600,
              last.bytes - first.bytes >= 256 * 1024 * 1024,
              Double(last.bytes) >= Double(first.bytes) * 1.5 else { return nil }
        // Require sustained increases, not a single allocation spike.
        let rising = zip(history, history.dropFirst()).filter { $0.bytes < $1.bytes }.count
        guard Double(rising) / Double(history.count - 1) >= 0.7 else { return nil }
        return last.bytes - first.bytes
    }
}

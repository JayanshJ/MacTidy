import CoreServices
import Darwin
import Foundation

/// A bounded, disposable cache. It never participates in deletion authorization.
public final class DiskMapIndex: @unchecked Sendable {
    public struct Aggregate: Codable, Sendable {
        public let item: ScanItem
        public let itemCount: Int
        public let newestModified: Date?
        public let complete: Bool
    }
    private struct Scope: Codable {
        let root: String
        let device: UInt64
        let inode: UInt64
        let volumeUUID: String
        let eventID: UInt64
        let complete: Bool
        let savedAt: Date
        let fullScanSeconds: Double?
        let incrementalSeconds: Double?
        let entries: [Aggregate]
    }
    private struct Store: Codable { let version: Int; var scopes: [Scope] }
    private struct Identity: Equatable { let device: UInt64; let inode: UInt64; let volumeUUID: String }
    private let lock = NSLock()
    private let file: URL
    private let maxBytes: Int
    private let maxScopes: Int
    private var memory: [String: Scope] = [:]
    private var monitors: [String: DiskMapJournal.Monitor] = [:]
    private struct Fingerprint: Equatable { let inode: UInt64; let bytes: Int64; let seconds: Int; let nanos: Int }
    private var fingerprint: Fingerprint?
    private var isWriting = false
    private var pendingScopes: [String: Scope] = [:]
    private let writeQueue = DispatchQueue(label: "MacTidy.DiskMapIndex.writer", qos: .utility)
    private let writeGroup = DispatchGroup()
    private static let version = 1

    public init(file: URL? = nil, maxBytes: Int = 8 * 1024 * 1024, maxScopes: Int = 20) {
        self.file = file ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/MacTidy/disk-map-index.json")
        self.maxBytes = max(1024, maxBytes)
        self.maxScopes = max(1, maxScopes)
    }

    private func identity(_ root: URL) -> Identity? {
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              let uuid = try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              !uuid.isEmpty else { return nil }
        return Identity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), volumeUUID: uuid)
    }

    private func read() -> Store? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes,
              let data = try? Data(contentsOf: file),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.version == Self.version, store.scopes.count <= maxScopes else { return nil }
        return store
    }
    private func diskFingerprint() -> Fingerprint? {
        var value = stat()
        guard lstat(file.path, &value) == 0 else { return nil }
        return Fingerprint(inode: UInt64(value.st_ino), bytes: value.st_size,
                           seconds: value.st_mtimespec.tv_sec, nanos: value.st_mtimespec.tv_nsec)
    }
    // Called while holding the index lock. Do not let a changed or corrupted
    // on-disk store be masked indefinitely by a memory snapshot.
    private func storedScope(root: URL) -> Scope? {
        let currentFingerprint = diskFingerprint()
        if !isWriting && currentFingerprint != fingerprint {
            memory.removeAll()
            monitors.removeAll()
            fingerprint = currentFingerprint
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let path = root.path
        guard let scope = memory[path] ?? read()?.scopes.first(where: { $0.root == path }),
              let identity = identity(root), scope.device == identity.device, scope.inode == identity.inode, scope.volumeUUID == identity.volumeUUID,
              scope.complete, scope.entries.allSatisfy(\.complete), scope.eventID > 0,
              Date().timeIntervalSince(scope.savedAt) >= 0, Date().timeIntervalSince(scope.savedAt) < 24 * 3600,
              Set(scope.entries.map { $0.item.url.standardizedFileURL.path }).count == scope.entries.count,
              Set(scope.entries.map { $0.item.id }).count == scope.entries.count,
              scope.entries.allSatisfy({ $0.item.url.deletingLastPathComponent().standardizedFileURL.path == path && $0.item.sizeBytes >= 0 && $0.itemCount >= 0 }) else { return nil }
        memory[path] = scope
        return scope
    }
    /// Snapshot is historical, not proof of current contents. Call refresh before
    /// presenting it as current. A changed volume or malformed cache is ignored.
    public func cached(root: URL) -> [Aggregate]? {
        lock.withLock { storedScope(root: root)?.entries }
    }
    /// Publish in memory immediately. Coalesce writes on a utility queue after
    /// results have been delivered; the disk index is always disposable.
    private func scheduleSave(_ scope: Scope) {
        lock.withLock { memory[scope.root] = scope; pendingScopes[scope.root] = scope }
        writeGroup.enter()
        writeQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
            defer { writeGroup.leave() }
            let pending: [Scope] = lock.withLock {
                let work = Array(pendingScopes.values)
                pendingScopes.removeAll()
                if !work.isEmpty { isWriting = true }
                return work
            }
            guard !pending.isEmpty else { return }
            var scopes = read()?.scopes ?? []
            for entry in pending.sorted(by: { $0.savedAt < $1.savedAt }) {
                scopes.removeAll { $0.root == entry.root }
                scopes.insert(entry, at: 0)
            }
            scopes = Array(scopes.prefix(maxScopes))
            var didWrite = false
            while true {
                guard let data = try? JSONEncoder().encode(Store(version: Self.version, scopes: scopes)) else { break }
                if data.count <= maxBytes {
                    do {
                        let parent = file.deletingLastPathComponent()
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                        try data.write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        didWrite = true
                    } catch { /* best effort: cache is never an authority */ }
                    break
                }
                guard !scopes.isEmpty else { break }
                scopes.removeLast()
            }
            lock.withLock {
                fingerprint = diskFingerprint()
                isWriting = false
                if didWrite {
                    let retained = Set(scopes.map(\.root)).union(pendingScopes.keys)
                    memory = memory.filter { retained.contains($0.key) }
                }
            }
        }
    }
    /// For tests and orderly shutdown; interactive scanning never waits here.
    public func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in
            writeGroup.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }

    /// Reads direct children and measures their trees. FSEvents only invalidates
    /// affected immediate-child subtrees; a journal gap forces a complete scan.
    public func refresh(root: URL, onItem: (@Sendable (Aggregate) -> Void)? = nil) async -> [Aggregate] {
        let result = await refreshResult(root: root, onItem: onItem)
        if let scope = result.scope { scheduleSave(scope) }
        return result.items
    }
    private func refreshResult(root: URL, onItem: (@Sendable (Aggregate) -> Void)? = nil) async -> (items: [Aggregate], complete: Bool, scope: Scope?) {
        let scanStartedAt = Date()
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var initialStat = stat()
        let haveInitialStat = lstat(root.path, &initialStat) == 0
        // Resolve the volume in parallel with the scan. The initial lstat and
        // final identity check still reject a root replacement during scanning.
        async let firstIdentity = Task.detached(priority: .userInitiated) { self.identity(root) }.value
        let old = lock.withLock { storedScope(root: root) }
        // Capture before walking so a subsequent replay includes changes that
        // race the scan; never advance to an ID captured after enumeration.
        let scanStartID = FSEventsGetCurrentEventId()
        let monitor: DiskMapJournal.Monitor? = old.flatMap { scope in
            guard scanStartID >= scope.eventID else { return nil }
            return monitorFor(root: root, since: scope.eventID)
        }
        let checkpoint = monitor?.changes(waitForHistory: true)
        let changes = checkpoint?.changes
        if let old, let checkpoint, !checkpoint.changes.requiresFullScan, checkpoint.changes.paths.isEmpty {
            monitor?.acknowledge(revision: checkpoint.revision)
            return (old.entries, true, nil)
        }
        // FSEvents can report /private/var for deleted paths while existing
        // paths use /var. Unknown paths are never ignored: invalidate all.
        let rootPath = Self.eventPath(root.path)
        let journalPaths = changes.map { Set($0.paths.map(Self.eventPath)) }
        let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
        let unrelatedEvent = journalPaths?.contains { $0 != rootPath && !$0.hasPrefix(rootPrefix) } ?? false
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return ([], false, nil) }
        let previous = Dictionary(uniqueKeysWithValues: (old?.entries ?? []).map { ($0.item.url.standardizedFileURL.path, $0) })
        var output: [Aggregate] = []
        var complete = true
        var toMeasure: [(url: URL, modified: Date?)] = []
        let affected = Set((journalPaths ?? []).map(Self.eventPath))
        let totalWeight = (old?.entries ?? []).reduce(0) { $0 + max($1.itemCount, 1) }
        let dirtyWeight = (old?.entries ?? []).filter { entry in
            let path = Self.eventPath(entry.item.url.standardizedFileURL.path)
            return affected.contains { $0 == rootPath || $0 == path || $0.hasPrefix(path + "/") }
        }.reduce(0) { $0 + max($1.itemCount, 1) }
        // If most indexed work is dirty, concurrent full scanning is likely
        // cheaper than a large sequence of incremental checks.
        let preferFull = Self.shouldScanWholeScope(hasChanges: !affected.isEmpty,
                                                   entries: old?.entries.count ?? 0,
                                                   totalWeight: totalWeight, dirtyWeight: dirtyWeight,
                                                   fullSeconds: old?.fullScanSeconds,
                                                   incrementalSeconds: old?.incrementalSeconds)
        for child in children {
            if Task.isCancelled { complete = false; break }
            guard let values = try? child.resourceValues(forKeys: keys) else { complete = false; continue }
            guard values.isSymbolicLink != true else { continue }
            let path = child.standardizedFileURL.path
            let normalized = Self.eventPath(path)
            let dirty = changes == nil || changes!.requiresFullScan || unrelatedEvent || preferFull || affected.contains { changed in
                changed == rootPath || changed == normalized || changed.hasPrefix(normalized + "/")
            }
            if !dirty, let cached = previous[path], cached.item.isDirectory == (values.isDirectory == true), cached.item.lastModified == values.contentModificationDate {
                output.append(cached); onItem?(cached)
            } else if values.isDirectory == true {
                toMeasure.append((child, values.contentModificationDate))
            } else if let size = values.totalFileAllocatedSize {
                let item = ScanItem(url: child, sizeBytes: Int64(size), isDirectory: false, lastModified: values.contentModificationDate)
                let aggregate = Aggregate(item: item, itemCount: 1, newestModified: values.contentModificationDate, complete: true)
                output.append(aggregate); onItem?(aggregate)
            } else { complete = false }
        }
        await withTaskGroup(of: Aggregate?.self) { group in
            var next = 0
            func submit() {
                guard next < toMeasure.count, !Task.isCancelled else { return }
                let work = toMeasure[next]; next += 1
                group.addTask { [self] in
                    guard !Task.isCancelled else { return nil }
                    return measureDirectory(work.url, modified: work.modified)
                }
            }
            let limit = max(1, min(4, Int(ProcessInfo.processInfo.environment["MACTIDY_SCAN_WORKERS"] ?? "4") ?? 4))
            for _ in 0..<min(limit, toMeasure.count) { submit() }
            while let result = await group.next() {
                if Task.isCancelled { group.cancelAll(); complete = false; break }
                if let result { complete = complete && result.complete; output.append(result); onItem?(result) }
                submit()
            }
        }
        let initialIdentity = await firstIdentity
        let scope: Scope?
        if !Task.isCancelled, complete, haveInitialStat, let initialIdentity,
           initialIdentity.device == UInt64(initialStat.st_dev), initialIdentity.inode == UInt64(initialStat.st_ino),
           initialIdentity == identity(root), scanStartID > 0 {
            let wasFull = old == nil || changes == nil || changes!.requiresFullScan || unrelatedEvent || preferFull
            let elapsed = Date().timeIntervalSince(scanStartedAt)
            scope = Scope(root: root.path, device: initialIdentity.device, inode: initialIdentity.inode, volumeUUID: initialIdentity.volumeUUID,
                          eventID: scanStartID, complete: true, savedAt: Date(),
                          fullScanSeconds: wasFull ? elapsed : old?.fullScanSeconds,
                          incrementalSeconds: wasFull ? old?.incrementalSeconds : elapsed, entries: output)
        } else { scope = nil }
        if let scope { lock.withLock { memory[scope.root] = scope } }
        if complete, !Task.isCancelled, let checkpoint { monitor?.acknowledge(revision: checkpoint.revision) }
        return (output, complete && !Task.isCancelled, scope)
    }

    static func shouldScanWholeScope(hasChanges: Bool, entries: Int, totalWeight: Int,
                                     dirtyWeight: Int, fullSeconds: Double?, incrementalSeconds: Double?) -> Bool {
        guard hasChanges else { return false }
        if let fullSeconds, let incrementalSeconds, incrementalSeconds >= fullSeconds { return true }
        return entries > 1 && totalWeight > 0 && Double(dirtyWeight) / Double(totalWeight) >= 0.7
    }

    private func monitorFor(root: URL, since: UInt64) -> DiskMapJournal.Monitor? {
        lock.withLock {
            if let monitor = monitors[root.path] { return monitor }
            guard let monitor = DiskMapJournal.Monitor(root: root, since: since) else { return nil }
            if monitors.count >= maxScopes, let key = monitors.keys.first { monitors.removeValue(forKey: key) }
            monitors[root.path] = monitor
            return monitor
        }
    }
    var activeMonitorCount: Int { lock.withLock { monitors.count } }
    private func currentMonitor(root: URL) -> DiskMapJournal.Monitor? {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        return lock.withLock { monitors[root.path] }
    }

    public enum Event: Sendable {
        case cached([Aggregate])
        case presented([Aggregate], validating: Bool)
        case measured(Aggregate)
        case finished([Aggregate], complete: Bool)
    }
    public func scan(root: URL) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                let snapshot = self.cached(root: root)
                if let snapshot, !Task.isCancelled {
                    continuation.yield(.cached(snapshot))
                    // Already caught up, with no observed changes: do no journal
                    // work or filesystem walk on the interactive path.
                    if let monitor = self.currentMonitor(root: root), monitor.isClean {
                        continuation.yield(.presented(snapshot, validating: false))
                        continuation.yield(.finished(snapshot, complete: true))
                        continuation.finish()
                        return
                    }
                    // This is explicitly a historical snapshot until replay
                    // completes. Yield it before starting any FSEvents work.
                    continuation.yield(.presented(snapshot, validating: true))
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled else { continuation.finish(); return }
                }
                let result = await self.refreshResult(root: root) { aggregate in
                    if !Task.isCancelled { continuation.yield(.measured(aggregate)) }
                }
                if !Task.isCancelled { continuation.yield(.finished(result.items, complete: result.complete)) }
                if let scope = result.scope { self.scheduleSave(scope) }
                continuation.finish()
                // Cold scans have no stream yet. Start one after the result is
                // delivered, replaying from the ID captured before the scan.
                if snapshot == nil, result.complete, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    let canonical = root.resolvingSymlinksInPath().standardizedFileURL
                    if let scope = self.lock.withLock({ self.storedScope(root: canonical) }) {
                        _ = self.monitorFor(root: canonical, since: scope.eventID)
                    }
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { worker.cancel() }
            }
        }
    }

    private static func eventPath(_ path: String) -> String { DiskMapJournal.normalizedPath(path) }

    private func measureDirectory(_ url: URL, modified: Date?) -> Aggregate {
        let measured = BulkWalker.aggregates(of: [url.path], materializingDataless: false)[0]
        let newest: Date? = [measured.newest, modified].compactMap { $0 }.max()
        return Aggregate(item: ScanItem(url: url, sizeBytes: measured.bytes, isDirectory: true, lastModified: modified),
                         itemCount: measured.count, newestModified: newest, complete: measured.complete && !Task.isCancelled)
    }
}

fileprivate struct JournalChanges: Sendable { var paths = Set<String>(); var requiresFullScan = false }

/// Replays the macOS journal from a persisted host event ID. Missing history,
/// event loss, root changes or timeout are all treated as a cache miss.
enum DiskMapJournal {
    fileprivate struct Checkpoint { let changes: JournalChanges; let revision: UInt64 }
    static func normalizedPath(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] {
            if path == "/private" + alias || path.hasPrefix("/private" + alias + "/") { return String(path.dropFirst("/private".count)) }
        }
        return path
    }
    static func requiresFullScan(flags: UInt32) -> Bool {
        let unsafeFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        return flags & unsafeFlags != 0
    }
    final class Monitor: @unchecked Sendable {
        private final class State: @unchecked Sendable {
            let lock = NSLock()
            let history = DispatchSemaphore(value: 0)
            let root: String
            init(root: String) { self.root = DiskMapJournal.normalizedPath(root) }
            var changes = JournalChanges()
            var historyDone = false
            var revision: UInt64 = 0
        }
        private let state: State
        private let queue: DispatchQueue
        private let stream: FSEventStreamRef
        init?(root: URL, since: UInt64) {
            let state = State(root: root.path)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(state).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
                let strings = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                state.lock.withLock {
                    for index in 0..<count {
                        let flag = flags[index]
                        if DiskMapJournal.requiresFullScan(flags: flag) { state.changes.requiresFullScan = true; state.revision &+= 1 }
                        if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { state.historyDone = true; state.history.signal() }
                        if let path = strings[index], flag & UInt32(kFSEventStreamEventFlagHistoryDone) == 0 {
                            let raw = URL(fileURLWithPath: String(cString: path)).standardizedFileURL.path
                            let changed = DiskMapJournal.normalizedPath(raw)
                            let prefix = state.root == "/" ? "/" : state.root + "/"
                            if changed == state.root { state.changes.requiresFullScan = true }
                            else if changed.hasPrefix(prefix), let name = changed.dropFirst(prefix.count).split(separator: "/").first {
                                let subtree = prefix + name
                                if state.changes.paths.count >= 4_096 { state.changes.requiresFullScan = true }
                                else { state.changes.paths.insert(String(subtree)) }
                            } else { state.changes.requiresFullScan = true }
                            state.revision &+= 1
                        }
                    }
                }
            }
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root.path] as CFArray, since, 0.05,
                                                   UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { return nil }
            let queue = DispatchQueue(label: "MacTidy.DiskMapJournal")
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil }
            self.state = state; self.queue = queue; self.stream = stream
        }
        var isClean: Bool {
            state.lock.withLock { state.historyDone && !state.changes.requiresFullScan && state.changes.paths.isEmpty }
        }
        fileprivate func changes(waitForHistory: Bool) -> Checkpoint? {
            if waitForHistory && !state.lock.withLock({ state.historyDone }) {
                guard state.history.wait(timeout: .now() + 3) == .success else { return nil }
            }
            return state.lock.withLock {
                guard state.historyDone else { return nil }
                return Checkpoint(changes: state.changes, revision: state.revision)
            }
        }
        func acknowledge(revision: UInt64) {
            state.lock.withLock {
                if state.revision == revision { state.changes = JournalChanges() }
            }
        }
        deinit {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            queue.sync {}
        }
    }
}

import Darwin
import Foundation

/// Directory sizing over `getattrlistbulk(2)`: one syscall returns a batch of
/// entries with name, type and allocated size, instead of one `stat` per
/// entry. Read-only. Symlinks are never followed (only real directories are
/// descended), so a walk can't double-count or escape its root. Unreadable
/// directories and entries are skipped silently.
///
/// Directories are shared between worker threads, so one huge tree (a 13 GB
/// app folder) is sized by every core instead of trailing the scan on one.
enum BulkWalker {
    enum Kind { case file, directory, symlink, other }

    struct Entry {
        let name: String
        let kind: Kind
        /// All forks' allocated bytes (what `.totalFileAllocatedSizeKey`
        /// reports). 0 for anything but regular files.
        let allocatedSize: Int64
        let modified: Date?
        let complete: Bool
    }

    struct Aggregate: Sendable { var bytes: Int64 = 0; var count: Int = 0; var newest: Date?; var complete = true }

    /// Allocated bytes of the regular files under each root, in order. Stops
    /// early (returning partial totals) when the calling task is cancelled.
    /// With `materializingDataless` off, a folder iCloud hasn't downloaded is
    /// skipped instead of being fetched just to list it.
    static func allocatedSizes(
        of roots: [String],
        materializingDataless: Bool = true,
        progress: (@Sendable (_ directory: String, _ bytes: Int64) -> Void)? = nil
    ) -> [Int64] {
        aggregates(of: roots, materializingDataless: materializingDataless, progress: progress).map(\.bytes)
    }

    static func aggregates(
        of roots: [String],
        materializingDataless: Bool = true,
        progress: (@Sendable (String, Int64) -> Void)? = nil
    ) -> [Aggregate] {
        guard !roots.isEmpty else { return [] }
        let queue = WorkQueue(
            roots: roots.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 },
            maxHelpers: max(0, min(ProcessInfo.processInfo.activeProcessorCount, 8) - 1)
        )
        work(queue, isHelper: false, materializingDataless: materializingDataless, progress: progress)
        return queue.totals
    }

    /// Runs `body` with this thread refusing to download dataless files and
    /// folders, then restores the thread's policy (pool threads get reused).
    static func withoutMaterializingDataless(_ body: () -> Void) {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }
        body()
    }

    private static func work(
        _ queue: WorkQueue,
        isHelper: Bool,
        materializingDataless: Bool,
        progress: (@Sendable (String, Int64) -> Void)?
    ) {
        guard materializingDataless else {
            withoutMaterializingDataless {
                drain(queue, isHelper: isHelper, materializingDataless: false, progress: progress)
            }
            return
        }
        drain(queue, isHelper: isHelper, materializingDataless: true, progress: progress)
    }

    private static func drain(
        _ queue: WorkQueue,
        isHelper: Bool,
        materializingDataless: Bool,
        progress: (@Sendable (String, Int64) -> Void)?
    ) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var files = 0
        while let item = queue.next(isHelper: isHelper) {
            // Only the calling thread runs inside the task, so only it can
            // see cancellation; it stops the helpers through the queue.
            if !isHelper, Task.isCancelled { queue.cancel(); return }
            var aggregate = Aggregate()
            var subdirectories: [WorkQueue.Work] = []
            let readComplete = read(item.path, followSymlink: item.isRoot, buffer: buffer) { entry in
                if !entry.complete { aggregate.complete = false }
                if entry.kind == .file || entry.kind == .directory {
                    aggregate.count += 1
                    if let date = entry.modified, aggregate.newest == nil || date > aggregate.newest! { aggregate.newest = date }
                }
                switch entry.kind {
                case .file:
                    aggregate.bytes += entry.allocatedSize
                    files += 1
                    if files % 512 == 0 { progress?(item.path, aggregate.bytes) }
                case .directory:
                    subdirectories.append(.init(path: item.path + "/" + entry.name,
                                                root: item.root, isRoot: false))
                case .symlink, .other:
                    break
                }
            }
            aggregate.complete = aggregate.complete && readComplete
            let helpers = queue.finish(item, aggregate: aggregate, adding: subdirectories)
            for _ in 0..<helpers {
                DispatchQueue.global(qos: .userInitiated).async {
                    work(queue, isHelper: true, materializingDataless: materializingDataless, progress: progress)
                }
            }
        }
    }

    private static let bufferSize = 128 * 1024

    /// Calls `visit` for each entry directly inside `directory`. The root of a
    /// walk may be a symlink the caller chose; below it, O_NOFOLLOW guards
    /// against a directory swapped for a link mid-walk.
    private static func read(
        _ directory: String,
        followSymlink: Bool,
        buffer: UnsafeMutableRawPointer,
        visit: (Entry) -> Void
    ) -> Bool {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | (followSymlink ? 0 : O_NOFOLLOW))
        if fd < 0 { return false }
        defer { close(fd) }
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        attrs.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        var complete = true
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, 0)
            if count == 0 { return complete }
            if count < 0 { return false }
            var cursor = buffer
            for _ in 0..<count {
                let length = Int(cursor.load(as: UInt32.self))
                if let entry = parse(cursor) { visit(entry) } else { complete = false }
                cursor += length
            }
        }
    }

    /// Decodes one packed record. Fields appear in attribute-bit order after
    /// the length and returned-attribute set; absent ones are omitted.
    private static func parse(_ record: UnsafeMutableRawPointer) -> Entry? {
        var field = record + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let error = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
            if error != 0 { return nil }
        }
        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let reference = field.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        field += MemoryLayout<attrreference_t>.size

        guard returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 else { return nil }
        let type = field.loadUnaligned(as: UInt32.self)
        field += MemoryLayout<UInt32>.size

        var modified: Date?
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            let time = field.loadUnaligned(as: timespec.self)
            field += MemoryLayout<timespec>.size
            modified = Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
        }
        let kind: Kind = switch type {
        case UInt32(VREG.rawValue): .file
        case UInt32(VDIR.rawValue): .directory
        case UInt32(VLNK.rawValue): .symlink
        default: .other
        }
        var size: Int64 = 0
        let hasSize = returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0
        if kind == .file, hasSize { size = field.loadUnaligned(as: Int64.self) }
        return Entry(name: name, kind: kind, allocatedSize: size, modified: modified,
                     complete: (kind != .file || hasSize) && ((kind != .file && kind != .directory) || modified != nil))
    }

    /// The directories still to read, shared by the calling thread and its
    /// helpers. A helper leaves as soon as the stack runs dry; the calling
    /// thread waits while others may still push subdirectories, and the walk
    /// is over when the stack is empty and no directory is being read.
    private final class WorkQueue: @unchecked Sendable {
        struct Work {
            let path: String
            let root: Int
            let isRoot: Bool
        }

        private let condition = NSCondition()
        private var stack: [Work]
        private var active = 0
        private var helpers = 0
        private let maxHelpers: Int
        private var cancelled = false
        private(set) var totals: [Aggregate]

        init(roots: [String], maxHelpers: Int) {
            stack = roots.enumerated().reversed().map { Work(path: $1, root: $0, isRoot: true) }
            totals = [Aggregate](repeating: Aggregate(), count: roots.count)
            self.maxHelpers = maxHelpers
        }

        func next(isHelper: Bool) -> Work? {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if !cancelled, let work = stack.popLast() {
                    active += 1
                    return work
                }
                if cancelled || active == 0 || isHelper {
                    if isHelper {
                        helpers -= 1
                        HelperBudget.release()
                    }
                    return nil
                }
                // Timed, so the calling thread rechecks cancellation even
                // while helpers hold every remaining directory.
                condition.wait(until: Date(timeIntervalSinceNow: 0.1))
                if Task.isCancelled { cancelled = true; condition.broadcast() }
            }
        }

        /// Records a read directory's bytes and pushes its subdirectories.
        /// Returns how many new helpers to start: one per spare directory
        /// beyond what the running workers will pick up next, up to the cap.
        func finish(_ work: Work, aggregate: Aggregate, adding subdirectories: [Work]) -> Int {
            condition.lock()
            defer { condition.unlock() }
            totals[work.root].bytes += aggregate.bytes
            totals[work.root].count += aggregate.count
            totals[work.root].complete = totals[work.root].complete && aggregate.complete
            if let date = aggregate.newest, totals[work.root].newest == nil || date > totals[work.root].newest! { totals[work.root].newest = date }
            stack.append(contentsOf: subdirectories)
            active -= 1
            if !subdirectories.isEmpty || active == 0 { condition.broadcast() }
            let spare = stack.count - 1
            let wanted = cancelled ? 0 : max(0, min(spare, maxHelpers - helpers))
            let start = HelperBudget.acquire(upTo: wanted)
            helpers += start
            return start
        }

        func cancel() {
            condition.lock()
            cancelled = true
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Helper threads across every walk in the process. A full scan runs a
    /// dozen walks at once on top of the Swift task pool; without a shared
    /// cap each would add its own helpers and put 30+ threads on the disk.
    private enum HelperBudget {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var inUse = 0
        static let limit = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)

        static func acquire(upTo wanted: Int) -> Int {
            guard wanted > 0 else { return 0 }
            return lock.withLock {
                let granted = min(wanted, limit - inUse)
                inUse += max(0, granted)
                return max(0, granted)
            }
        }

        static func release() {
            lock.withLock { inUse -= 1 }
        }
    }
}

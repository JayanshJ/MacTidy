import Foundation

/// What's in a folder, by structure rather than content: its biggest children,
/// kinds of file and newest change. Enough for a person, or an AI model, to
/// reason about a folder MacTidy has no rule for. No file is ever opened.
public struct FolderProfile: Sendable, Equatable {
    public struct Child: Sendable, Equatable, Identifiable {
        public let name: String
        public let bytes: Int64
        public let isDirectory: Bool
        public var id: String { name }

        public init(name: String, bytes: Int64, isDirectory: Bool) {
            self.name = name
            self.bytes = bytes
            self.isDirectory = isDirectory
        }
    }

    /// Generic on purpose: these words go to the AI even with file paths off,
    /// so they must never carry a name. A file's extension only picks one.
    public enum FileKind: String, Sendable, CaseIterable {
        case databases, video, images, audio, archives, documents, logs, code
        case aiModels = "AI models"
        case diskImages = "disk images"
        case other = "other files"

        static func of(extension ext: String) -> FileKind {
            switch ext.lowercased() {
            case "sqlite", "sqlite3", "db", "ldb", "realm", "wal", "shm": .databases
            case "mp4", "mov", "m4v", "mkv", "avi", "webm", "mpg", "mpeg", "braw", "prores": .video
            case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "tif", "bmp", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "svg": .images
            case "mp3", "m4a", "aac", "wav", "flac", "ogg", "aiff", "opus", "caf": .audio
            case "zip", "gz", "tgz", "tar", "bz2", "xz", "zst", "7z", "rar", "xip", "pkg", "vsix", "asar": .archives
            case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "md", "rtf", "csv", "epub": .documents
            case "log", "ips", "crash", "dmp", "diag": .logs
            case "js", "mjs", "ts", "py", "pyc", "swift", "c", "h", "cpp", "rs", "go", "java", "class", "jar", "rb", "wasm", "node", "dylib", "so", "o", "a", "json", "html", "css": .code
            case "gguf", "safetensors", "onnx", "mlmodel", "mlmodelc", "ckpt", "pt", "pth": .aiModels
            case "dmg", "img", "iso", "qcow2", "vmdk", "vdi", "sparseimage", "sparsebundle", "hdd": .diskImages
            default: .other
            }
        }
    }

    public struct KindShare: Sendable, Equatable, Identifiable {
        public let kind: FileKind
        public let bytes: Int64
        public let files: Int
        public var id: String { kind.rawValue }

        public init(kind: FileKind, bytes: Int64, files: Int) {
            self.kind = kind
            self.bytes = bytes
            self.files = files
        }
    }

    public let url: URL
    public let totalBytes: Int64
    /// Largest first, at most `maxChildren`.
    public let children: [Child]
    public let childCount: Int
    /// Largest first. Stops at `maxFiles` files; see `isPartial`.
    public let kinds: [KindShare]
    public let newestChange: Date?
    public let isPartial: Bool

    public init(url: URL, totalBytes: Int64, children: [Child], childCount: Int,
                kinds: [KindShare], newestChange: Date?, isPartial: Bool = false) {
        self.url = url
        self.totalBytes = totalBytes
        self.children = children
        self.childCount = childCount
        self.kinds = kinds
        self.newestChange = newestChange
        self.isPartial = isPartial
    }

    static let maxChildren = 8
    static let maxFiles = 100_000

    /// Reads names, sizes and dates. Symlinks aren't followed, and whatever
    /// can't be read is skipped silently.
    public static func read(_ url: URL) async -> FolderProfile {
        let children = await DiskScanner.topLevelScan(root: url)
        return await Task.detached(priority: .userInitiated) {
            let walk = walk(url)
            return FolderProfile(
                url: url,
                totalBytes: children.reduce(0) { $0 + $1.sizeBytes },
                children: children.prefix(maxChildren).map {
                    Child(name: $0.url.lastPathComponent, bytes: $0.sizeBytes, isDirectory: $0.isDirectory)
                },
                childCount: children.count,
                kinds: walk.kinds, newestChange: walk.newest, isPartial: walk.isPartial)
        }.value
    }

    private static func walk(_ root: URL) -> (kinds: [KindShare], newest: Date?, isPartial: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, errorHandler: { _, _ in true }
        ) else { return ([], nil, false) }
        var tally: [FileKind: (bytes: Int64, files: Int)] = [:]
        var newest: Date?
        var seen = 0
        for case let file as URL in files {
            guard !Task.isCancelled else { break }
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            seen += 1
            if seen > maxFiles { return (shares(tally), newest, true) }
            let kind = FileKind.of(extension: file.pathExtension)
            let entry = tally[kind] ?? (0, 0)
            tally[kind] = (entry.bytes + Int64(values.totalFileAllocatedSize ?? 0), entry.files + 1)
            if let date = values.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
        }
        return (shares(tally), newest, false)
    }

    private static func shares(_ tally: [FileKind: (bytes: Int64, files: Int)]) -> [KindShare] {
        tally.map { KindShare(kind: $0.key, bytes: $0.value.bytes, files: $0.value.files) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// The answer MacTidy can give by itself, in a sentence or three. Works
    /// with no AI provider set up.
    public func summary(now: Date = Date()) -> String {
        guard totalBytes > 0 else { return "This folder is empty, or MacTidy can't read inside it." }
        var sentences: [String] = []
        let measured = kinds.reduce(0) { $0 + $1.bytes }
        if let top = kinds.first, measured > 0 {
            let share = Double(top.bytes) / Double(measured)
            if top.kind == .other {
                sentences.append("Mostly files with no familiar type.")
            } else if share >= 0.5 {
                sentences.append("Mostly \(top.kind.rawValue): \(top.bytes.formattedBytes) of \(totalBytes.formattedBytes).")
            } else {
                sentences.append("A mix of files, led by \(top.kind.rawValue) at \(top.bytes.formattedBytes).")
            }
        }
        if let biggest = children.first, childCount > 1, Double(biggest.bytes) / Double(totalBytes) >= 0.5 {
            sentences.append("\(biggest.name) alone is \(biggest.bytes.formattedBytes).")
        }
        if let newestChange, newestChange <= now {
            sentences.append("Last changed \(AppUninstaller.lastUsedLabel(for: newestChange, now: now).lowercased()).")
        }
        return sentences.joined(separator: " ")
    }
}

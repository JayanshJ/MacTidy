import Foundation
import Testing
@testable import CoreKit

@Suite("TrashLog + Restorer")
struct TrashLogTests {
    /// Trashes a real file, logs it, then restores it — verifying the round
    /// trip that the Undo/Recently-Trashed feature relies on.
    @Test func restoreMovesItemBackAndClearsLogEntry() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appending(path: "mactidy-trash-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let storage = fm.temporaryDirectory.appending(path: "trash-log-\(UUID().uuidString).json")
        let log = TrashLog(storageURL: storage)
        defer {
            try? fm.removeItem(at: sandbox)
            try? fm.removeItem(at: storage)
        }

        let file = sandbox.appending(path: "precious.txt")
        try Data("important".utf8).write(to: file)
        let originalPath = file.path

        // Trash it for real (not dry run) so there's a Trash location to undo.
        let trashLocation = try Trasher.trash(file)
        #expect(!fm.fileExists(atPath: originalPath))
        #expect(fm.fileExists(atPath: trashLocation.path))

        let record = TrashRecord(
            original: file, trashLocation: trashLocation,
            date: Date(), bytes: 9, kind: .deletion)
        log.append([record])
        #expect(log.load().count == 1)

        // Restore: the file must reappear at its original path…
        let restored = try Restorer.restore(log.load().first!)
        #expect(restored.path == originalPath)
        #expect(fm.fileExists(atPath: originalPath))
        #expect(!fm.fileExists(atPath: trashLocation.path))
        #expect(try Data(contentsOf: file) == Data("important".utf8))

        // …and the log entry must be removed.
        log.remove(log.load().first!.id)
        #expect(log.load().isEmpty)
    }

    @Test func dryRunRecordsAreNotPersisted() throws {
        let fm = FileManager.default
        let storage = fm.temporaryDirectory.appending(path: "trash-log-\(UUID().uuidString).json")
        let log = TrashLog(storageURL: storage)
        defer { try? fm.removeItem(at: storage) }

        // A record with no trash location (dry run) must be filtered out.
        log.append([TrashRecord(
            original: URL(fileURLWithPath: "/tmp/none"), trashLocation: nil,
            date: Date(), bytes: 0, kind: .deletion)])
        #expect(log.load().isEmpty)
    }

    @Test func restoreSurvivesCollisionAtOriginalPath() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appending(path: "mactidy-trash-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let storage = fm.temporaryDirectory.appending(path: "trash-log-\(UUID().uuidString).json")
        let log = TrashLog(storageURL: storage)
        defer {
            try? fm.removeItem(at: sandbox)
            try? fm.removeItem(at: storage)
        }

        let file = sandbox.appending(path: "collide.txt")
        try Data("old".utf8).write(to: file)
        let trashLocation = try Trasher.trash(file)
        // Re-create something at the original path before restoring.
        try Data("new occupant".utf8).write(to: file)

        let record = TrashRecord(
            original: file, trashLocation: trashLocation,
            date: Date(), bytes: 3, kind: .deletion)
        log.append([record])
        let restored = try Restorer.restore(log.load().first!)
        // Restore must land beside the occupant, not overwrite it.
        #expect(restored.path != file.path)
        #expect(fm.fileExists(atPath: restored.path))
        #expect(try Data(contentsOf: file) == Data("new occupant".utf8))
        #expect(try Data(contentsOf: restored) == Data("old".utf8))
    }

    @Test func restoreFailsGracefullyIfTrashEmptied() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appending(path: "mactidy-trash-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let file = sandbox.appending(path: "gone.txt")
        try Data("x".utf8).write(to: file)
        let trashLocation = try Trasher.trash(file)
        // Simulate the user emptying the Trash.
        try fm.removeItem(at: trashLocation)

        let record = TrashRecord(
            original: file, trashLocation: trashLocation,
            date: Date(), bytes: 1, kind: .deletion)
        #expect(throws: Restorer.RestoreError.self) { try Restorer.restore(record) }
    }
}
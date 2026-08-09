import AppKit
import Foundation

/// There is no official "is Full Disk Access granted" API, so we probe a
/// known TCC-protected file. We actually open it rather than using
/// `isReadableFile` — `access(2)` can report stale results under TCC,
/// while `open(2)` is what TCC really gates.
public enum FullDiskAccess {
    public static var isGranted: Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: probe) else { return false }
        try? handle.close()
        return true
    }

    @MainActor
    public static func openSettingsPane() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

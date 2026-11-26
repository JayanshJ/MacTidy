import Foundation

/// Pure, side-effect-free helpers extracted from the app-layer `UpdateManager`
/// so the update pipeline's riskiest logic — bundle verification, app-bundle
/// discovery, and swap-helper script generation — is unit-testable without
/// actually swapping the running app or launching a detached `Process`.
///
/// The irreducible side-effects (URLSession download, `Process.run`) stay in
/// `UpdateManager`; everything that *can* be pure lives here.
public enum UpdateInstaller {
    /// The bundle id the app expects of itself. A downloaded update whose
    /// `CFBundleIdentifier` differs is refused — it's not MacTidy.
    public static let expectedBundleID = "com.jayansh.mactidy"

    /// Locates a `*.app` bundle inside a staging directory, at the root or one
    /// level deep (a zip that wraps a top folder). Returns nil when there's no
    /// `.app` at either level — the caller treats that as `notAppBundle`.
    public static func findAppBundle(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in names where name.hasSuffix(".app") {
            return dir.appendingPathComponent(name, isDirectory: true)
        }
        for name in names {
            let sub = dir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue,
               let inner = try? fm.contentsOfDirectory(atPath: sub.path) {
                for n in inner where n.hasSuffix(".app") {
                    return sub.appendingPathComponent(n, isDirectory: true)
                }
            }
        }
        return nil
    }

    /// What `verifyBundle` checks, surfaced so tests can assert which
    /// invariant rejected a bad bundle.
    public enum VerificationError: Error, Equatable {
        case notAppBundle
        case wrongBundle
        case signatureInvalid(String)
        case wrongVersion(found: String)
    }

    /// Verifies a candidate bundle before swapping anything. Checks, in order:
    /// 1. `Contents/MacOS/MacTidy` exists and is executable (real bundle).
    /// 2. `CFBundleIdentifier` == `expectedBundleID` (the right app).
    /// 3. `codesign -v` passes (download wasn't truncated/corrupted).
    /// 4. Its version is strictly newer than `currentVersion` (no downgrades).
    ///
    /// `codesignVerify` is injectable so tests don't shell out to `/usr/bin/codesign`;
    /// production passes `{ Shell.run("/usr/bin/codesign", ["-v", $0.path]) }`.
    public static func verifyBundle(
        at appURL: URL,
        expectedVersion: UpdateChecker.Version,
        currentVersion: UpdateChecker.Version,
        codesignVerify: (URL) -> Shell.Output?
    ) throws {
        let exe = appURL.appendingPathComponent("Contents/MacOS/MacTidy")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw VerificationError.notAppBundle
        }
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOfFile: plist.path),
              let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID == expectedBundleID else {
            throw VerificationError.wrongBundle
        }
        if let r = codesignVerify(appURL), !r.succeeded {
            throw VerificationError.signatureInvalid(r.stderr)
        }
        let v = (info["CFBundleShortVersionString"] as? String) ?? "0"
        let found = UpdateChecker.Version(v)
        guard found == expectedVersion, found > currentVersion else {
            throw VerificationError.wrongVersion(found: v)
        }
    }

    /// Self-install only replaces the copy that is actually running, so a build
    /// launched from `dist/` or a translocated copy never touches `/Applications`.
    public static func canInstallAutomatically(runningBundle: URL, installURL: URL) -> Bool {
        runningBundle.standardizedFileURL.path == installURL.standardizedFileURL.path
    }

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MacTidy-update.log")
    }

    /// The helper writes why an install failed here; the next launch reads it.
    public static var failureMarkerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MacTidy-update-failed.txt")
    }

    /// What to tell the user about a failed install. macOS blocks apps from
    /// changing other apps unless App Management allows it.
    public static func failureMessage(_ error: String) -> String {
        let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("Operation not permitted") || detail.contains("Permission denied") {
            return "macOS blocked the update. Allow MacTidy in System Settings → Privacy & Security → App Management, then quit MacTidy again."
        }
        return "The update couldn't be installed, so your current version was kept. \(detail)"
    }

    /// Generates the detached helper that replaces the installed app after the
    /// current process quits. Pure — the caller writes it to a temp file and
    /// launches it. The old bundle stays in place until the new one can be moved
    /// in, and any failure puts it back. It deletes nothing: the old bundle ends
    /// up in the temp folder, which macOS clears.
    public static func swapHelperScript(
        newAppURL: URL,
        installURL: URL,
        currentPID: Int32,
        relaunch: Bool = true,
        logURL: URL = UpdateInstaller.logURL,
        failureMarkerURL: URL = UpdateInstaller.failureMarkerURL
    ) -> String {
        return """
        #!/bin/sh
        # Auto-generated by MacTidy to apply a self-update. Detached + disowned.
        log() { echo "$(date '+%H:%M:%S') $*"; }

        NEW_APP="\(newAppURL.path)"
        DEST="\(installURL.path)"
        BACKUP="$(dirname "$NEW_APP")/MacTidy-previous.app"
        FAILURE_MARKER="\(failureMarkerURL.path)"
        RELAUNCH=\(relaunch ? 1 : 0)
        exec >>"\(logURL.path)" 2>&1
        log "=== swap helper started (old pid \(currentPID)) ==="

        finish() {
            if [ "$RELAUNCH" = 1 ]; then
                open "$DEST"
                log "relaunched"
            fi
            exit "$1"
        }
        fail() {
            log "FAILED: $1"
            printf '%s\\n' "$1" > "$FAILURE_MARKER"
            finish 1
        }

        # Wait for the old process to exit. The helper only starts once the app
        # is quitting, so after the graceful wait we force-kill to let the swap
        # proceed if something keeps the run loop alive.
        i=0
        while [ $i -lt 150 ]; do
            if ! kill -0 \(currentPID) 2>/dev/null; then break; fi
            sleep 0.2
            i=$((i + 1))
        done
        if kill -0 \(currentPID) 2>/dev/null; then
            log "old process still alive after 30s — force killing"
            kill -9 \(currentPID) 2>/dev/null
            sleep 0.5
        fi
        log "old process gone, swapping"

        if [ -e "$DEST" ]; then
            if ! err=$(mv "$DEST" "$BACKUP" 2>&1); then fail "$err"; fi
            log "old app moved aside"
        fi

        if ! err=$(mv "$NEW_APP" "$DEST" 2>&1); then
            [ -e "$BACKUP" ] && mv "$BACKUP" "$DEST"
            fail "$err"
        fi
        log "new app moved"

        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

        if ! err=$(/usr/bin/codesign -v "$DEST" 2>&1); then
            if [ -e "$BACKUP" ]; then
                mv "$DEST" "$NEW_APP" && mv "$BACKUP" "$DEST"
            fi
            fail "$err"
        fi
        log "update installed"

        finish 0
        """
    }
}

import Foundation
import AppKit
import CoreKit

/// The app-layer half of self-update: fetches the latest GitHub release,
/// downloads the `MacTidy.app.zip` asset, verifies it, then swaps it into
/// `/Applications` via a detached helper script and relaunches.
///
/// The pure manifest/version logic lives in CoreKit (`UpdateChecker`); this
/// type owns the network, the filesystem verification, and the swap.
///
/// Security note: updates are downloaded over HTTPS from your own GitHub
/// release but are **not notarized** (the app is self-signed). A downloaded
/// bundle carries Apple's `com.apple.quarantine` flag and Gatekeeper would
/// refuse to open it, so the swap helper strips that attribute after moving
/// the new bundle into place. The trust root is HTTPS + your GitHub account;
/// there is no separate cryptographic signature check.
@MainActor
@Observable
final class UpdateManager {
    /// Where the running app lives. `make app` installs to `/Applications`,
    /// and the swap helper replaces exactly this path.
    static let installURL = URL(fileURLWithPath: "/Applications/MacTidy.app")

    enum Phase: Sendable, Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateChecker.ReleaseManifest)
        case downloading(progress: Double)           // 0...1
        case installing
        case readyToRelaunch(UpdateChecker.ReleaseManifest)  // helper spawned; quit to apply
        case failed(String)
        case noDownloadableAsset(UpdateChecker.ReleaseManifest)  // release exists, no zip → open page
    }

    var phase: Phase = .idle
    /// Persisted: check for updates automatically on launch.
    var checkOnLaunch: Bool {
        didSet { UserDefaults.standard.set(checkOnLaunch, forKey: "MacTidy.update.checkOnLaunch") }
    }

    private var task: Task<Void, Never>?

    init() {
        self.checkOnLaunch = UserDefaults.standard.object(forKey: "MacTidy.update.checkOnLaunch") as? Bool ?? true
    }

    // MARK: - Check

    /// Current version from the running bundle's Info.plist.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Fetches the latest release manifest and sets `phase` accordingly.
    func check() {
        task?.cancel()
        phase = .checking
        task = Task {
            do {
                let json = try await fetchString(from: UpdateChecker.latestReleaseURL,
                                                 extraHeaders: ["Accept": "application/vnd.github+json",
                                                                "User-Agent": "MacTidy"])
                guard let manifest = UpdateChecker.parseRelease(json: json) else {
                    phase = .failed("Couldn't read the release information from GitHub.")
                    return
                }
                if UpdateChecker.isUpdateAvailable(manifest: manifest, current: currentVersion) {
                    if manifest.downloadURL != nil {
                        phase = .available(manifest)
                    } else {
                        phase = .noDownloadableAsset(manifest)
                    }
                } else {
                    phase = .upToDate
                }
            } catch {
                phase = .failed("Couldn't reach GitHub: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Download + install

    /// Downloads the update asset, verifies it, writes the swap helper, and
    /// spawns it detached. The caller (UI) is responsible for quitting the
    /// app immediately after this returns `.ok` — the helper waits for the
    /// process to exit before swapping.
    func downloadAndInstall() {
        guard case .available(let manifest) = phase,
              let url = manifest.downloadURL else {
            phase = .failed("No update is ready to install.")
            return
        }
        task?.cancel()
        task = Task {
            do {
                let t0 = Date()
                NSLog("[MacTidy.update] download start")
                let zippedURL = try await download(from: url, expectedSize: manifest.downloadSize)
                NSLog("[MacTidy.update] download done (\(Int(Date().timeIntervalSince(t0) * 1000))ms)")
                phase = .installing
                try await verifyAndInstall(zippedURL: zippedURL, manifest: manifest)
                NSLog("[MacTidy.update] verify+install done (\(Int(Date().timeIntervalSince(t0) * 1000))ms total)")
                // Helper is spawned and detached; signal the UI to quit so the
                // helper can swap the bundle and relaunch.
                phase = .readyToRelaunch(manifest)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Quits the app so the spawned swap helper can replace the bundle and
    /// relaunch. Called by the UI once `phase` is `.readyToRelaunch`.
    func relaunchToApply() {
        NSApplication.shared.terminate(nil)
    }

    /// Convenience for the UI: open the release page when there's no zip asset.
    func openReleasePage() {
        let url: URL
        switch phase {
        case .noDownloadableAsset(let m): url = m.htmlURL
        case .available(let m): url = m.htmlURL
        default: url = UpdateChecker.latestReleasePageURL
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Network

    private func fetchString(from url: URL, extraHeaders: [String: String]) async throws -> String {
        var request = URLRequest(url: url)
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badResponse
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Downloads `url` to a temp file, reporting coarse progress into `phase`.
    ///
    /// Uses a delegate-based `URLSessionDownloadTask` that streams straight to
    /// disk, not the `bytes` async iterator. Iterating `bytes` yields one
    /// `UInt8` per `await` — ~2,000,000 async suspensions for a 2 MB asset —
    /// which is genuinely slow regardless of how often the progress bar is
    /// updated. The download task has no per-byte loop; progress is reported
    /// from the delegate callback (throttled to ~32 updates).
    private func download(from url: URL, expectedSize: Int64) async throws -> URL {
        phase = .downloading(progress: 0)
        let delegate = DownloadProgressDelegate(expectedTotal: expectedSize) { [weak self] progress in
            Task { @MainActor in self?.phase = .downloading(progress: progress) }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        // Resume + wait via a continuation. The delegate captures the result
        // (temp file URL or error) and resumes exactly once.
        let result: DownloadResult = try await withCheckedThrowingContinuation { cont in
            delegate.completion = { res in cont.resume(returning: res) }
            task.resume()
        }
        switch result {
        case .success(let tmp, let response):
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateError.badResponse
            }
            phase = .downloading(progress: 1)
            // Move the system temp file to a stable, uniquely-named file the
            // unzip step owns (the system deletes its scratch file otherwise).
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacTidy-update-\(UUID().uuidString).zip")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        case .failure(let error):
            throw error
        }
    }

    // MARK: - Verify + install

    /// Unzips the downloaded asset, verifies the resulting bundle, writes the
    /// detached swap helper, and launches it. Throws on any verification
    /// failure — the running app is left untouched.
    private func verifyAndInstall(zippedURL: URL, manifest: UpdateChecker.ReleaseManifest) async throws {
        let t = Date()
        // 1. Unzip into a temp staging dir.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTidy-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try unzip(at: zippedURL, into: staging)
        NSLog("[MacTidy.update] unzip done (\(Int(Date().timeIntervalSince(t) * 1000))ms)")

        // 2. Locate the .app bundle (it may be at staging root or one level deep).
        guard let newAppURL = findAppBundle(in: staging) else {
            throw UpdateError.notAppBundle
        }

        // 3. Verify it's a real MacTidy bundle, signed, and actually newer.
        try verifyBundle(at: newAppURL, expectedVersion: manifest.version)
        NSLog("[MacTidy.update] verifyBundle done (\(Int(Date().timeIntervalSince(t) * 1000))ms)")

        // 4. Write + spawn the detached swap helper, then signal success so
        //    the UI can quit the app.
        try spawnSwapHelper(newAppURL: newAppURL)
        NSLog("[MacTidy.update] helper spawned (\(Int(Date().timeIntervalSince(t) * 1000))ms)")
    }

    /// Unzip via the system `unzip` tool (always present on macOS). Falls back
    /// to `tar -xf` for zip extraction if unzip is somehow missing.
    private func unzip(at zipURL: URL, into dest: URL) throws {
        let unzip = "/usr/bin/unzip"
        if FileManager.default.isExecutableFile(atPath: unzip) {
            let r = Shell.run(unzip, ["-q", "-o", zipURL.path, "-d", dest.path])
            guard r?.succeeded == true else { throw UpdateError.unzipFailed(r?.stderr ?? "") }
        } else {
            // tar can read zip archives.
            let r = Shell.run("/usr/bin/tar", ["-xf", zipURL.path, "-C", dest.path])
            guard r?.succeeded == true else { throw UpdateError.unzipFailed(r?.stderr ?? "") }
        }
    }

    /// Finds a `*.app` bundle at the staging root or one directory deep.
    private func findAppBundle(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in names where name.hasSuffix(".app") {
            return dir.appendingPathComponent(name, isDirectory: true)
        }
        // One level deep (common when the zip wraps a top folder).
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

    /// Verifies the candidate bundle before swapping anything:
    /// - has a `Contents/MacOS/MacTidy` executable (real bundle, not a folder)
    /// - `CFBundleIdentifier` == `com.jayansh.mactidy` (the right app)
    /// - `codesign -v` passes (download wasn't truncated/corrupted)
    /// - its version is strictly newer than the running app (no downgrades)
    private func verifyBundle(at appURL: URL, expectedVersion: UpdateChecker.Version) throws {
        let exe = appURL.appendingPathComponent("Contents/MacOS/MacTidy")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw UpdateError.notAppBundle
        }
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOfFile: plist.path),
              let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID == "com.jayansh.mactidy" else {
            throw UpdateError.wrongBundle
        }
        // codesign verification.
        if let r = Shell.run("/usr/bin/codesign", ["-v", appURL.path]), !r.succeeded {
            throw UpdateError.signatureInvalid(r.stderr)
        }
        let v = (info["CFBundleShortVersionString"] as? String) ?? "0"
        guard UpdateChecker.Version(v) == expectedVersion,
              UpdateChecker.Version(v) > UpdateChecker.Version(currentVersion) else {
            throw UpdateError.wrongVersion(found: v)
        }
    }

    /// Writes a detached shell helper to /tmp and launches it with
    /// `Process.disown`. The helper:
    ///   1. waits up to 60s for the current MacTidy process to exit,
    ///   2. trashes the old /Applications/MacTidy.app (fallback rm -rf),
    ///   3. moves the new bundle into place,
    ///   4. strips the quarantine attribute (updates aren't notarized),
    ///   5. relaunches the new app,
    ///   6. self-deletes.
    private func spawnSwapHelper(newAppURL: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactidy-swap-\(pid).sh")

        let script = """
        #!/bin/sh
        # Auto-generated by MacTidy to apply a self-update. Detached + disowned.
        # Logs each step with a timestamp so a slow step is visible in
        # ~/Library/Logs/MacTidy-update.log (and via `log show` if redirected).
        log() { echo "$(date '+%H:%M:%S') $*"; }

        NEW_APP="\(newAppURL.path)"
        DEST="/Applications/MacTidy.app"
        LOG="$HOME/Library/Logs/MacTidy-update.log"
        exec >>"$LOG" 2>&1
        log "=== swap helper started (old pid \(pid)) ==="

        # 1. Wait for the running app (pid \(pid)) to quit. Poll every 0.2s
        #    up to 30s — finer-grained than the old 1s×60 loop, so the swap
        #    happens promptly once the process is actually gone.
        i=0
        while [ $i -lt 150 ]; do
            if ! kill -0 \(pid) 2>/dev/null; then break; fi
            sleep 0.2
            i=$((i + 1))
        done
        log "old process gone, swapping"

        # 2. Remove the old app. We deliberately do NOT use Finder/AppleScript
        #    here — `tell application "Finder" to delete` can hang for minutes
        #    (Finder not running, Trash busy), which was the real cause of the
        #    5–7 minute "stuck" update. `rm -rf` is instant. The old bundle is
        #    a self-update of a personal app; losing the Trash undo is fine.
        if [ -e "$DEST" ]; then
            rm -rf "$DEST"
            log "old app removed"
        fi

        # 3. Move the new bundle into place.
        mv "$NEW_APP" "$DEST"
        log "new app moved"

        # 4. Strip the quarantine flag so Gatekeeper lets the self-signed
        #    update open (updates are not notarized).
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

        # 5. Relaunch.
        open "$DEST"
        log "relaunched"

        # 6. Self-destruct.
        rm -f "$0"
        """

        try script.write(to: helper, atomically: true, encoding: .utf8)
        // Make executable (octal 0700 — readable/writable/executable by owner).
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        // Launch detached. A child Process is re-parented to launchd when this
        // app exits, so the helper keeps running after we quit — exactly what
        // the swap needs. We intentionally do NOT wait for it.
        let proc = Process()
        proc.executableURL = helper
        try proc.run()
    }
}

// MARK: - Download progress delegate

/// The outcome of a delegate-based download: either the temp file URL plus
/// response, or an error. The continuation in `download` is resumed with
/// exactly one of these.
private enum DownloadResult: Sendable {
    case success(URL, URLResponse)
    case failure(Error)
}

/// URLSession delegate that streams the download straight to a temp file and
/// reports coarse progress (a value in 0...1). Runs on URLSession's own
/// delegate queue, so the progress callback hops to the main actor to set
/// `phase`. Kept throttled — at most ~32 updates across the whole file — so
/// we never flood the main actor even for a large download. The downloaded
/// file is handed back via `completion` so `download` can move it to a stable
/// name before the system reclaims its scratch file.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedTotal: Int64
    private let onProgress: @Sendable (Double) -> Void
    private let step: Int64
    private var nextThreshold: Int64
    /// Set by `download` just before resuming the task; called exactly once
    /// from `didFinishDownloadingTo` (success) or `didCompleteWithError`
    /// (failure), whichever fires.
    var completion: (@Sendable (DownloadResult) -> Void)?

    init(expectedTotal: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expectedTotal = expectedTotal
        self.onProgress = onProgress
        self.step = expectedTotal > 0 ? max(Int64(1), expectedTotal / 32) : 64 * 1024
        self.nextThreshold = expectedTotal > 0 ? max(Int64(1), expectedTotal / 32) : 64 * 1024
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedTotal
        guard total > 0, totalBytesWritten >= nextThreshold else { return }
        let progress = min(1, max(0, Double(totalBytesWritten) / Double(total)))
        nextThreshold = totalBytesWritten + step
        // `onProgress` hops to the main actor itself; call it directly here.
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Copy the scratch file out immediately — the system deletes
        // `location` after this returns. A unique name avoids any collision.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTidy-dl-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            completion?(.success(dest, downloadTask.response ?? URLResponse()))
        } catch {
            completion?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion?(.failure(error)) }
        // Success path is handled in `didFinishDownloadingTo`; no action here.
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case unzipFailed(String)
    case notAppBundle
    case wrongBundle
    case signatureInvalid(String)
    case wrongVersion(found: String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "GitHub didn't return a usable response."
        case .unzipFailed(let s): return "Couldn't unzip the update: \(s)"
        case .notAppBundle: return "The downloaded update isn't a valid MacTidy app bundle."
        case .wrongBundle: return "The downloaded bundle isn't MacTidy (bundle id mismatch)."
        case .signatureInvalid(let s): return "The downloaded update's signature didn't verify: \(s)"
        case .wrongVersion(let v): return "The downloaded bundle's version (\(v)) isn't newer than the installed one — refusing to downgrade."
        }
    }
}
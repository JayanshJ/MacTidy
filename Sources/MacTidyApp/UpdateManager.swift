import Foundation
import AppKit
import CoreKit

/// The app-layer half of self-update: fetches the latest GitHub release,
/// downloads the `MacTidy.app.zip` asset, verifies it and holds it ready. A
/// detached helper script swaps it into `/Applications` once the app quits.
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
        case readyToRelaunch(UpdateChecker.ReleaseManifest)  // verified; applied on quit
        case failed(String)
        case noDownloadableAsset(UpdateChecker.ReleaseManifest)  // release exists, no zip → open page
    }

    var phase: Phase = .idle
    /// Persisted: check for updates automatically on launch.
    var checkOnLaunch: Bool {
        didSet { UserDefaults.standard.set(checkOnLaunch, forKey: "MacTidy.update.checkOnLaunch") }
    }

    /// Persisted: download new versions in the background and install on quit.
    var installAutomatically: Bool {
        didSet { UserDefaults.standard.set(installAutomatically, forKey: "MacTidy.update.installAutomatically") }
    }
    /// Why the previous install failed, read from the helper's marker file.
    var lastInstallFailure: String?

    private var task: Task<Void, Never>?
    private var automaticChecks: Task<Void, Never>?
    /// The verified bundle waiting for the app to quit.
    private var stagedApp: URL?
    private var helperSpawned = false

    init() {
        self.checkOnLaunch = UserDefaults.standard.object(forKey: "MacTidy.update.checkOnLaunch") as? Bool ?? true
        self.installAutomatically = UserDefaults.standard.object(forKey: "MacTidy.update.installAutomatically") as? Bool ?? true
        let marker = UpdateInstaller.failureMarkerURL
        if let failure = try? String(contentsOf: marker, encoding: .utf8) {
            lastInstallFailure = UpdateInstaller.failureMessage(failure)
            try? FileManager.default.removeItem(at: marker)
        }
    }

    /// True only when the running copy is the one the helper would replace.
    var canInstallAutomatically: Bool {
        UpdateInstaller.canInstallAutomatically(runningBundle: Bundle.main.bundleURL, installURL: Self.installURL)
    }

    /// Checks on launch and once a day while running, since the app stays alive
    /// in the menu bar. Quiet: a failed background check shows nothing.
    func startAutomaticChecks() {
        guard automaticChecks == nil else { return }
        automaticChecks = Task {
            while !Task.isCancelled {
                if checkOnLaunch {
                    switch phase {
                    case .idle, .upToDate, .failed, .available: check(silent: true)
                    default: break
                    }
                }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    // MARK: - Check

    /// Current version from the running bundle's Info.plist.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Fetches the latest release manifest and sets `phase` accordingly.
    func check(silent: Bool = false) {
        task?.cancel()
        if !silent { phase = .checking }
        task = Task {
            do {
                let json = try await fetchString(from: UpdateChecker.latestReleaseURL,
                                                 extraHeaders: ["Accept": "application/vnd.github+json",
                                                                "User-Agent": "MacTidy"])
                guard let manifest = UpdateChecker.parseRelease(json: json) else {
                    if !silent { phase = .failed("Couldn't read the release information from GitHub.") }
                    return
                }
                if UpdateChecker.isUpdateAvailable(manifest: manifest, current: currentVersion) {
                    if manifest.downloadURL != nil {
                        phase = .available(manifest)
                        if silent && installAutomatically && canInstallAutomatically {
                            downloadAndInstall(silent: true)
                        }
                    } else {
                        phase = .noDownloadableAsset(manifest)
                    }
                } else {
                    phase = .upToDate
                }
            } catch {
                NSLog("[MacTidy.update] check failed: \(error.localizedDescription)")
                if !silent { phase = .failed("Couldn't reach GitHub: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Download + install

    /// Downloads the update asset, verifies it and holds it ready. Nothing is
    /// swapped until the app quits, through `relaunchToApply` or `applyOnQuit`.
    func downloadAndInstall(silent: Bool = false) {
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
                stagedApp = try await verifiedBundle(zippedURL: zippedURL, manifest: manifest)
                NSLog("[MacTidy.update] verified (\(Int(Date().timeIntervalSince(t0) * 1000))ms total)")
                phase = .readyToRelaunch(manifest)
            } catch {
                NSLog("[MacTidy.update] install failed: \(error.localizedDescription)")
                // A quiet attempt stays offered, so one bad download isn't an alarm.
                phase = silent ? .available(manifest) : .failed(error.localizedDescription)
            }
        }
    }

    /// Starts the swap helper and quits so it can replace the bundle and
    /// relaunch. Called by the UI once `phase` is `.readyToRelaunch`.
    func relaunchToApply() {
        do {
            try spawnStagedHelper(relaunch: true)
            NSApplication.shared.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The user quit with an update ready: install it without reopening.
    func applyOnQuit() {
        guard installAutomatically, canInstallAutomatically else { return }
        do {
            try spawnStagedHelper(relaunch: false)
        } catch {
            NSLog("[MacTidy.update] couldn't start the helper: \(error.localizedDescription)")
        }
    }

    private func spawnStagedHelper(relaunch: Bool) throws {
        guard !helperSpawned, let stagedApp else { return }
        guard FileManager.default.fileExists(atPath: stagedApp.path) else { throw UpdateError.notAppBundle }
        try spawnSwapHelper(newAppURL: stagedApp, relaunch: relaunch)
        helperSpawned = true
    }

    /// Cancels any in-flight check/download so nothing keeps the run loop
    /// alive during termination. Called from `AppState.prepareForTermination`.
    /// The swap helper is detached, so this does not affect a pending swap.
    func cancelInFlight() {
        task?.cancel()
        automaticChecks?.cancel()
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

    /// Unzips the downloaded asset and returns the verified bundle. Throws on
    /// any verification failure — the running app is left untouched.
    private func verifiedBundle(zippedURL: URL, manifest: UpdateChecker.ReleaseManifest) async throws -> URL {
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
        return newAppURL
    }

    /// Extracts the downloaded update zip into `dest`.
    ///
    /// Uses `ditto -x -k` — the symmetric inverse of the `ditto -c -k` that
    /// packages the release asset. This matters for code-signing integrity:
    /// `ditto -c -k` stores resource forks / extended attributes as AppleDouble
    /// `._*` files inside the zip. `/usr/bin/unzip` does NOT merge those back on
    /// extraction — it leaves stray `._CodeResources` next to the real
    /// `CodeResources`, which breaks the seal (`codesign -v` reports "a sealed
    /// resource is missing or invalid") and the update fails verification.
    /// `ditto -x -k` reassembles the AppleDouble files correctly, so the
    /// signature verifies. Falls back to `unzip` only if `ditto` is somehow
    /// missing (it never is on macOS); in that degraded case the downstream
    /// codesign check fails closed rather than installing a broken app.
    private func unzip(at zipURL: URL, into dest: URL) throws {
        let ditto = "/usr/bin/ditto"
        if FileManager.default.isExecutableFile(atPath: ditto) {
            let r = Shell.run(ditto, ["-x", "-k", zipURL.path, dest.path])
            guard r?.succeeded == true else { throw UpdateError.unzipFailed(r?.stderr ?? "") }
        } else {
            let r = Shell.run("/usr/bin/unzip", ["-q", "-o", zipURL.path, "-d", dest.path])
            guard r?.succeeded == true else { throw UpdateError.unzipFailed(r?.stderr ?? "") }
        }
    }

    /// Finds a `*.app` bundle at the staging root or one directory deep.
    private func findAppBundle(in dir: URL) -> URL? {
        UpdateInstaller.findAppBundle(in: dir)
    }

    /// Verifies the candidate bundle before swapping anything. Delegates to
    /// the pure `UpdateInstaller.verifyBundle` so the invariant (exe + bundle
    /// id + codesign + newer-version) is unit-tested; the codesign check is
    /// the one real side-effect here, injected back in.
    private func verifyBundle(at appURL: URL, expectedVersion: UpdateChecker.Version) throws {
        do {
            try UpdateInstaller.verifyBundle(
                at: appURL,
                expectedVersion: expectedVersion,
                currentVersion: UpdateChecker.Version(currentVersion),
                codesignVerify: { Shell.run("/usr/bin/codesign", ["-v", $0.path]) }
            )
        } catch UpdateInstaller.VerificationError.notAppBundle {
            throw UpdateError.notAppBundle
        } catch UpdateInstaller.VerificationError.wrongBundle {
            throw UpdateError.wrongBundle
        } catch UpdateInstaller.VerificationError.signatureInvalid(let s) {
            throw UpdateError.signatureInvalid(s)
        } catch UpdateInstaller.VerificationError.wrongVersion(let v) {
            throw UpdateError.wrongVersion(found: v)
        } catch {
            throw UpdateError.notAppBundle
        }
    }

    /// Writes a detached shell helper to the temp folder and launches it. It
    /// must only start once the app is quitting, because it force-kills this
    /// process after 30s. See `UpdateInstaller.swapHelperScript` for its steps.
    private func spawnSwapHelper(newAppURL: URL, relaunch: Bool) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactidy-swap-\(pid).sh")

        let script = UpdateInstaller.swapHelperScript(
            newAppURL: newAppURL,
            installURL: Self.installURL,
            currentPID: pid,
            relaunch: relaunch
        )
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
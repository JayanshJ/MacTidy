import SwiftUI
import CoreKit

/// Full Disk Access setup. Polls every second so it moves on the moment
/// access lands, explains *why* a grant that looks "on" isn't working, offers
/// a one-click fix for each cause, and can always be skipped — the user is
/// never locked out of the app.
struct FDAOnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var resetMessage: String?
    @State private var isResetting = false

    private var status: FDAStatus { state.fdaStatus }
    private var bundleID: String { Bundle.main.bundleIdentifier ?? "com.jayansh.mactidy" }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                header
                checklist
                steps
                actions
                Button("Continue without Full Disk Access") { state.fdaSkipped = true }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                    .help("Scans still run, but anything inside ~/Library macOS protects will be missing.")
            }
            .padding(40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .task {
            // Auto-detect the grant; the view disappears (and this task is
            // cancelled) as soon as it's seen.
            while !Task.isCancelled {
                state.refreshFDA()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Full Disk Access needed")
                .font(.system(size: 26, weight: .semibold))
            Text("MacTidy scans ~/Library, app data and caches, which macOS protects. Without access, results are silently incomplete.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Live checklist

    private var checklist: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            row(ok: false,
                title: "Full Disk Access",
                detail: "Not granted yet. Checking every second.",
                spinning: true)
            if status.issues.contains(.translocated) {
                row(ok: false, title: "App location",
                    detail: "macOS is running a quarantined copy. Move MacTidy to /Applications and open it from there; grants to this copy won't stick.")
            } else if status.issues.contains(.notAppBundle) {
                row(ok: false, title: "App location",
                    detail: "Running as a bare binary, so macOS asks on behalf of your terminal. Run the app bundle instead (make run).")
            } else {
                row(ok: true, title: "App location", detail: Bundle.main.bundlePath)
            }
            if status.issues.contains(.staleGrant) {
                row(ok: false, title: "Old permission found",
                    detail: "A previous MacTidy build had access. The MacTidy switch in System Settings belongs to that build, so it looks on but this one is denied. Use “Reset old permission” below, then add MacTidy again.")
            }
            if status.issues.contains(.unstableSignature) {
                row(ok: nil, title: "Signature: per-build",
                    detail: "This build is ad-hoc signed, so macOS ties access to this exact build. After every rebuild or update an existing MacTidy entry goes stale. Run `make cert` once and rebuild to make access survive updates.")
            } else {
                row(ok: true, title: "Signature: stable", detail: status.signing.identifier ?? "")
            }
        }
        .cardStyle()
    }

    /// ok: true = green check, false = red cross, nil = orange warning.
    private func row(ok: Bool?, title: String, detail: String, spinning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Group {
                if spinning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: ok == true ? "checkmark.circle.fill"
                          : ok == false ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok == true ? Theme.Status.good
                                         : ok == false ? Theme.Status.blocked : Theme.Status.caution)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Steps + fixes

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("How to grant it").font(.headline)
            Text("1. Open System Settings → Privacy & Security → Full Disk Access.")
            Text("2. If MacTidy is already listed and switched on, that is an older build: select it and click −, or use “Reset old permission” below.")
            Text("3. Click +, choose MacTidy in Applications (or drag it in from Finder), and switch it on.")
            Text("4. If macOS offers “Quit & Reopen”, accept. Otherwise this screen moves on by itself.")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.md) {
            Button {
                FullDiskAccess.openSettingsPane()
            } label: {
                Text("Open System Settings").padding(.horizontal, Theme.Spacing.md)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            HStack(spacing: Theme.Spacing.lg) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                if status.signing.isAdHoc || status.issues.contains(.staleGrant) {
                    Button(isResetting ? "Resetting…" : "Reset old permission") { resetOldPermission() }
                        .disabled(isResetting)
                        .help("Removes MacTidy's Full Disk Access entry so this build can be added fresh. Only removes access.")
                }
                Button("Relaunch") { relaunch() }
                    .help("macOS sometimes applies a new grant only after a restart.")
            }
            .buttonStyle(.link)
            .font(Theme.Font.body)
            if let resetMessage {
                Text(resetMessage).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func resetOldPermission() {
        isResetting = true
        let id = bundleID
        Task {
            let out = await Task.detached { FullDiskAccess.resetGrant(bundleID: id) }.value
            isResetting = false
            if let out, out.succeeded {
                resetMessage = "Old entry removed. Now add MacTidy in System Settings (step 3) and switch it on."
                FullDiskAccess.openSettingsPane()
            } else {
                resetMessage = "Couldn't remove it automatically. In System Settings, select MacTidy and click −, then add it again."
            }
        }
    }

    private func relaunch() {
        // Detached shell outlives us, waits for exit, then reopens the bundle.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// Shown above the app while running without Full Disk Access.
struct LimitedModeBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.caution)
            Text("Limited mode: no Full Disk Access, so results inside ~/Library are incomplete.")
                .font(.callout)
            Spacer()
            Button("Fix") { state.fdaSkipped = false }
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Status.caution.opacity(0.12))
    }
}

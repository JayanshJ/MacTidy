import SwiftUI
import CoreKit

/// The "Updates" section of Settings. Binds `AppState.updates` (an
/// `UpdateManager`) and exposes check-now / download-and-install / open-page
/// actions, plus the launch-check toggle. The UI reflects the manager's
/// `phase` so a single source of truth drives every state.
struct UpdateSettingsSection: View {
    @Environment(AppState.self) private var state
    /// Dismisses the Settings sheet. The "Quit & Relaunch" button lives inside
    /// that sheet, and `NSApp.terminate` can stall while a modal SwiftUI
    /// sheet is still presented — so we dismiss the sheet before quitting, and
    /// defer the actual terminate a beat so the dismissal animation finishes.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var updates = state.updates
        Section {
            Toggle("Check for updates on launch", isOn: $updates.checkOnLaunch)
                .help("Quietly checks GitHub for a newer release when the app opens. Never auto-installs.")

            HStack {
                Text("Installed version")
                Spacer()
                Text("v\(state.updates.currentVersion)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }

            statusRow

            actionsRow
        } header: {
            Text("Updates")
        } footer: {
            Text("Checks the MacTidy GitHub repository for a newer release. Updates download over HTTPS and replace the app in /Applications, then relaunch. They are not notarized (the app is self-signed), so the quarantine flag is removed on install — the trust root is HTTPS plus your own GitHub release.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch state.updates.phase {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking GitHub…") }
        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.Status.good)
        case .available(let m):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Update available", systemImage: "arrow.up.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Text("v\(m.version.raw)").font(.headline).monospacedDigit()
                }
                if !m.notes.isEmpty {
                    Text(m.notes).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
        case .noDownloadableAsset(let m):
            VStack(alignment: .leading, spacing: 4) {
                Label("v\(m.version.raw) is on GitHub", systemImage: "arrow.up.circle")
                    .foregroundStyle(Theme.accent)
                Text("This release has no downloadable app bundle attached. Open the release page to install manually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading update…")
                ProgressView(value: p)
            }
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Verifying…") }
        case .readyToRelaunch(let m):
            Label("v\(m.version.raw) is ready — quit to apply and relaunch.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.Status.good)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var actionsRow: some View {
        HStack {
            Button {
                state.updates.check()
            } label: {
                Label("Check Now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)

            Spacer()

            switch state.updates.phase {
            case .available:
                Button {
                    state.updates.downloadAndInstall()
                } label: {
                    Label("Download & Install…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            case .noDownloadableAsset:
                Button {
                    state.updates.openReleasePage()
                } label: {
                    Label("Open Release Page", systemImage: "safari")
                }
                .buttonStyle(.bordered)
            case .readyToRelaunch:
                Button {
                    // Close the Settings sheet first — terminating with a
                    // modal sheet still presented can hang the run loop and
                    // the app never quits. Give the dismissal animation a beat
                    // to finish, then terminate. The swap helper (already
                    // spawned during download-and-install) is waiting for this
                    // process to exit; once it does, it swaps the bundle and
                    // relaunches.
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        state.updates.relaunchToApply()
                    }
                } label: {
                    Label("Quit & Relaunch", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Status.good)
            case .downloading, .installing:
                EmptyView()
            default:
                EmptyView()
            }
        }
    }

    /// True while a check/download/install is in flight — disables Check Now.
    private var isBusy: Bool {
        switch state.updates.phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
}
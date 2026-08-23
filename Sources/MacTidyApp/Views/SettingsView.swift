import SwiftUI
import CoreKit

/// App preferences: dry-run default, extra allowed roots, auto-scan-on-launch,
/// and log retention. Everything here is persisted via `AppState`.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var showRootPicker = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacTidy").font(.headline)
                        Text("Version \(AppVersion.full)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let icon = NSImage(named: "AppIcon") ?? bundledAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            Section("Safety") {
                @Bindable var state = state
                Toggle("Dry run by default", isOn: $state.dryRun)
                    .help("Preview deletions without touching anything. You can still override per action.")
                Text("Deletion always means Move to Trash. A hard denylist protects /System, your documents, photos, and media no matter what a scan proposes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(state.extraAllowedRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(root.path).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button(role: .destructive) {
                            state.removeExtraAllowedRoot(root)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from allow-list")
                    }
                }
                Button {
                    showRootPicker = true
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
            } header: {
                Text("Allowed folders")
            } footer: {
                Text("Roots the safety policy will let MacTidy trash inside, on top of your home, /Applications, /usr/local, and /opt/homebrew. Useful for an external dev volume. Symlinks are resolved first, so a link into a protected area is still rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Scanning") {
                @Bindable var state = state
                Toggle("Scan automatically on launch", isOn: $state.autoScanOnLaunch)
                    .help("Run a category scan when the app opens, if nothing is cached.")
            }

            Section {
                @Bindable var state = state
                Picker("Keep log history for", selection: $state.logRetentionDays) {
                    Text("Forever (cap at 500 trash / 1000 cleanup entries)").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
            } header: {
                Text("Log retention")
            } footer: {
                Text("Old entries are pruned from the Recently Trashed list and reclaim history. Trashed items themselves stay in the Trash until you empty it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileImporter(
            isPresented: $showRootPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                state.addExtraAllowedRoot(url)
            }
        }
    }

    private var bundledAppIcon: NSImage? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: "AppIcon", withExtension: "icns")
            ?? bundle.url(forResource: "AppIcon", withExtension: "png")
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}
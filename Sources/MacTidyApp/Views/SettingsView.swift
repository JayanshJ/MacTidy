import SwiftUI
import CoreKit

/// App preferences: dry-run default, extra allowed roots, auto-scan-on-launch,
/// and log retention. Everything here is persisted via `AppState`.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var showRootPicker = false
    @State private var apiKeyInput = ""
    @State private var keyStatus: String?
    @State private var keyStatusGood = false
    @State private var isTestingConnection = false
    @State private var connectionStatus: String?
    @State private var connectionStatusGood = false

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
                Toggle("Preview before deleting", isOn: $state.dryRun)
                    .help("Scan and review without trashing anything. You can still override per action.")
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

            // MARK: - Menu bar & alerts
            Section {
                @Bindable var monitor = state.monitor
                Toggle("Notify me when space piles up", isOn: $monitor.notificationsEnabled)
                    .help("A quick background check runs every 6 hours and alerts you only when reclaimable space crosses your threshold AND has grown since the last alert.")
                if monitor.notificationsEnabled {
                    Picker("Alert me above", selection: $monitor.thresholdBytes) {
                        Text("500 MB").tag(Int64(536_870_912))
                        Text("1 GB").tag(Int64(1_073_741_824))
                        Text("2 GB").tag(Int64(2_147_483_648))
                        Text("5 GB").tag(Int64(5_368_709_120))
                    }
                    .pickerStyle(.menu)
                }
                if let lastChecked = state.monitor.lastChecked {
                    Text("Last quick check: \(lastChecked.formatted(date: .abbreviated, time: .shortened)) — \(state.monitor.reclaimableBytes.formattedBytes) reclaimable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Menu bar & alerts")
            } footer: {
                Text("MacTidy keeps a menu bar icon with a live quick check. The quick check covers fast categories (caches, DerivedData, old installers) — open the app for the full scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - AI
            Section {
                @Bindable var state = state
                Picker("Provider", selection: $state.aiConfig.provider) {
                    ForEach(AIProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                if state.aiConfig.provider != .none {
                    TextField("Model", text: $state.aiConfig.model, prompt: Text(state.aiConfig.provider.defaultModel))
                        .autocorrectionDisabled()
                }
                if state.aiConfig.provider == .ollama {
                    TextField("Ollama base URL", text: $state.aiConfig.ollamaBaseURL, prompt: Text(AIConfig.defaultOllamaURL))
                        .autocorrectionDisabled()
                }
                if state.aiConfig.provider.requiresAPIKey {
                    SecureField("API key", text: $apiKeyInput)
                        .autocorrectionDisabled()
                    if let keyStatus {
                        Text(keyStatus)
                            .font(.caption)
                            .foregroundStyle(keyStatusGood ? Color.secondary : Color.orange)
                    }
                    Button("Save key to Keychain") { saveKey() }
                        .disabled(apiKeyInput.isEmpty)
                    Button("Remove stored key", role: .destructive) { removeKey() }
                        .disabled(KeychainHelper.load(for: state.aiConfig.provider) == nil)
                }
            } header: {
                Text("AI assistant")
            } footer: {
                Text("BYO key — stored in the macOS Keychain, never sent anywhere except the provider you choose. Ollama runs locally; cloud providers (OpenAI, Anthropic) need your own API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                @Bindable var state = state
                Toggle("Send file paths to model", isOn: $state.aiConfig.sendFilePaths)
                    .help("Off by default. When on, file names/paths are sent for richer per-file reasoning. Only a privacy concern for cloud providers — Ollama runs on your Mac.")
                if state.aiConfig.sendFilePaths && state.aiConfig.provider != .ollama && state.aiConfig.provider != .none {
                    Label("File paths will leave your Mac via \(state.aiConfig.provider.displayName).", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if state.aiConfig.provider != .none {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTestingConnection {
                            HStack { ProgressView().controlSize(.small); Text("Testing…") }
                        } else {
                            Label("Test connection", systemImage: "network")
                        }
                    }
                    .disabled(isTestingConnection)
                    if let connectionStatus {
                        Text(connectionStatus)
                            .font(.caption)
                            .foregroundStyle(connectionStatusGood ? Color.secondary : Color.orange)
                    }
                }
            } header: {
                Text("Privacy & connection")
            } footer: {
                Text("By default MacTidy sends only category labels, item counts, byte sizes, and staleness to the model — never file paths.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: - AI key + connection helpers

    private func saveKey() {
        let provider = state.aiConfig.provider
        do {
            try KeychainHelper.save(apiKeyInput, for: provider)
            keyStatus = "Key saved to Keychain."
            keyStatusGood = true
            apiKeyInput = ""
        } catch {
            keyStatus = "Failed to save key: \(error.localizedDescription)"
            keyStatusGood = false
        }
    }

    private func removeKey() {
        let provider = state.aiConfig.provider
        do {
            try KeychainHelper.delete(for: provider)
            keyStatus = "Stored key removed."
            keyStatusGood = true
        } catch {
            keyStatus = "Failed to remove key: \(error.localizedDescription)"
            keyStatusGood = false
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }
        guard let advisor = state.advisor else {
            connectionStatus = "No advisor configured."
            connectionStatusGood = false
            return
        }
        let result = await advisor.testConnection(config: state.aiConfig)
        connectionStatus = result
        connectionStatusGood = result.hasPrefix("Connected")
    }
}
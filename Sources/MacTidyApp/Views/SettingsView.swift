import SwiftUI
import CoreKit

/// App preferences: extra allowed roots, auto-scan-on-launch, and log
/// retention. Everything here is persisted via `AppState`.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var showRootPicker = false
    @State private var showDevRootPicker = false
    @State private var showCleanupHistory = false
    @State private var apiKeyInput = ""
    @State private var keyStatus: String?
    @State private var keyStatusGood = false
    @State private var isVerifyingKey = false
    @State private var revealKey = false
    @State private var storedKeyExists = false
    @State private var isTestingConnection = false
    @State private var connectionStatus: String?
    @State private var connectionStatusGood = false
    @State private var ollamaDetection: OllamaDetector.Detection?
    @State private var isDetectingOllama = false
    /// The job being added/edited in the schedule editor sheet; nil when the
    /// sheet is closed.
    @State private var editingSchedule: ScheduledJob?
    @State private var isNewSchedule = false

    var body: some View {
        TabView {
            Form {
                aboutSection
                appearanceSection
                scanningSection
                UpdateSettingsSection()
                menuBarSection
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                safetySection
                allowedFoldersSection
                devFoldersSection
            }
            .formStyle(.grouped)
            .tabItem { Label("Folders", systemImage: "folder") }

            Form {
                schedulesSection
                logsSection
            }
            .formStyle(.grouped)
            .tabItem { Label("Schedules", systemImage: "calendar") }

            Form {
                aiSection
                privacySection
            }
            .formStyle(.grouped)
            .tabItem { Label("AI", systemImage: "wand.and.stars") }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .fileImporter(
            isPresented: $showRootPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                state.addExtraAllowedRoot(url)
            }
        }
        .fileImporter(
            isPresented: $showDevRootPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                state.addCustomDevRoot(url)
            }
        }
        .sheet(isPresented: $showCleanupHistory) {
            CleanupHistoryView().frame(width: 560, height: 520)
        }
        .frame(width: 640, height: 600)
        .onAppear {
            if ollamaDetection == nil { refreshOllamaModels() }
            refreshStoredKeyStatus()
        }
        .onChange(of: state.aiConfig.provider) { _, _ in
            apiKeyInput = ""
            keyStatus = nil
            revealKey = false
            refreshStoredKeyStatus()
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
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
                        // The app icon asset is full-bleed (the squircle plate
                        // fills its frame), so at the same nominal size it reads
                        // visually larger than the SF Symbols around it. Inset
                        // it slightly so it sits in the row like the other icons.
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                            .padding(4)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }

    }

    @ViewBuilder
    private var safetySection: some View {
            Section("Safety") {
                Text("Every deletion moves to the Trash — undo from the Recently Trashed list. A hard denylist protects /System, your documents, photos, and media no matter what a scan proposes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

    }

    @ViewBuilder
    private var allowedFoldersSection: some View {
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

    }

    @ViewBuilder
    private var devFoldersSection: some View {
            Section {
                ForEach(state.customDevRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder.badge.gearshape").foregroundStyle(.secondary)
                        Text(root.path).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button(role: .destructive) {
                            state.removeCustomDevRoot(root)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from dev folders")
                    }
                }
                Button {
                    showDevRootPicker = true
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
            } header: {
                Text("Developer folders")
            } footer: {
                Text("MacTidy scans these folders for build artifacts, node_modules, Rust targets, etc. Add any folder where you keep code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

    }

    @ViewBuilder
    private var scanningSection: some View {
            Section("Scanning") {
                @Bindable var state = state
                Toggle("Scan automatically on launch", isOn: $state.autoScanOnLaunch)
                    .help("Run a category scan when the app opens, if nothing is cached.")
                Stepper("Old installers cutoff: \(state.installerMinAgeDays) days", value: $state.installerMinAgeDays, in: 7...365, step: 7)
                Stepper("Stale screenshots cutoff: \(state.screenshotMinAgeDays) days", value: $state.screenshotMinAgeDays, in: 7...365, step: 7)
            }

    }

    @ViewBuilder
    private var menuBarSection: some View {
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
                Text("MacTidy keeps a menu bar icon with a live quick check. The quick check covers fast categories (user caches, DerivedData, old installers, crash reports, HTTP storage) — open the app for the full scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

    }

    @ViewBuilder
    private var aiSection: some View {
            // MARK: - AI
            Section {
                @Bindable var state = state
                Picker("Provider", selection: $state.aiConfig.provider) {
                    ForEach(AIProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                if state.aiConfig.provider != .none {
                    modelField
                }
                if state.aiConfig.provider == .ollama {
                    TextField("Ollama base URL", text: $state.aiConfig.ollamaBaseURL, prompt: Text(AIConfig.defaultOllamaURL))
                        .autocorrectionDisabled()
                        .onChange(of: state.aiConfig.ollamaBaseURL) { _, _ in refreshOllamaModels() }
                }
                if state.aiConfig.provider.offersAPIKey {
                    // Stored-key status line — makes it obvious whether a key
                    // is already on file for this provider, so the user doesn't
                    // have to infer it from whether the Remove button is live.
                    HStack(spacing: 6) {
                        Image(systemName: storedKeyExists
                            ? "checkmark.seal.fill"
                            : "key.slash")
                            .foregroundStyle(storedKeyExists ? Theme.Status.good : Color.secondary)
                        Text(storedKeyExists
                            ? "A key is stored in the Keychain for \(state.aiConfig.provider.displayName)."
                            : "No key stored for \(state.aiConfig.provider.displayName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Group {
                        if revealKey {
                            TextField("API key", text: $apiKeyInput)
                                .autocorrectionDisabled()
                                .textContentType(.password)
                        } else {
                            SecureField("API key", text: $apiKeyInput)
                                .autocorrectionDisabled()
                        }
                    }
                    HStack {
                        Toggle("Reveal", isOn: $revealKey)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("Show the key as you type it.")
                        if storedKeyExists {
                            Button("Fill from Keychain") { fillFromKeychain() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .help("Load the stored key into the field to view or re-save it.")
                        }
                    }
                    if let keyStatus {
                        HStack(spacing: 6) {
                            if isVerifyingKey { ProgressView().controlSize(.small) }
                            Text(keyStatus)
                                .font(.caption)
                                .foregroundStyle(keyStatusGood ? Color.secondary : Color.orange)
                        }
                    }
                    Button {
                        Task { await saveAndVerifyKey() }
                    } label: {
                        if isVerifyingKey {
                            HStack { ProgressView().controlSize(.small); Text("Verifying…") }
                        } else {
                            Text("Save & Verify")
                        }
                    }
                    .disabled(apiKeyInput.isEmpty || isVerifyingKey)
                    .help("Save the key to the Keychain and verify it with a cheap call to the provider.")
                    if storedKeyExists {
                        Button("Remove stored key", role: .destructive) { removeKey() }
                            .disabled(isVerifyingKey)
                    }
                }
                if state.aiConfig.provider == .none {
                    ollamaOneClick
                }
            } header: {
                Text("AI assistant")
            } footer: {
                Text("BYO key — stored in the macOS Keychain, never sent anywhere except the provider you choose. Ollama runs locally and needs no key (one is optional, for Ollama behind an auth proxy); cloud providers (OpenAI, Anthropic) need your own API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

    }

    @ViewBuilder
    private var privacySection: some View {
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

    }

    @ViewBuilder
    private var logsSection: some View {
            Section {
                @Bindable var state = state
                Picker("Keep log history for", selection: $state.logRetentionDays) {
                    Text("Forever (cap at 500 trash / 1000 cleanup entries)").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                Button {
                    showCleanupHistory = true
                } label: {
                    Label("View Cleanup History…", systemImage: "clock.arrow.circlepath")
                }
            } header: {
                Text("Log retention & history")
            } footer: {
                Text("Old entries are pruned from the Recently Trashed list and reclaim history. Trashed items themselves stay in the Trash until you empty it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

    }

    private var appearanceSection: some View {
        Section("Appearance") {
            @Bindable var state = state
            Picker("Theme", selection: $state.appearance) {
                Text("Match System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Scheduled cleanup

    /// The scheduled-cleanup section: one row per job (toggle, cadence,
    /// time, categories) plus an Add button. Edits open a sheet with the
    /// full editor (`ScheduleEditor`). Jobs are restricted to safe
    /// (`isPreselectable`) categories — automated runs never touch
    /// suggest-only categories, Docker, or uninstall.
    @ViewBuilder
    private var schedulesSection: some View {
        Section {
            @Bindable var state = state
            if state.schedules.isEmpty {
                Text("No scheduled cleanups. Add one to run automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(state.schedules) { job in
                scheduleRow(job)
            }
            Button {
                editingSchedule = ScheduledJob()
                isNewSchedule = true
            } label: {
                Label("Add schedule", systemImage: "plus")
            }
        } header: {
            Text("Scheduled cleanup")
        } footer: {
            Text("Runs automatically via launchd — even when MacTidy is closed. Only safe categories (caches, build artifacts, old installers) are auto-trashed; suggest-only categories like node_modules and iOS backups are never touched automatically. Every item still passes the same safety check as a manual cleanup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editingSchedule) { job in
            ScheduleEditor(job: job, isNew: isNewSchedule) { saved in
                var jobs = state.schedules
                if let idx = jobs.firstIndex(where: { $0.id == saved.id }) {
                    jobs[idx] = saved
                } else {
                    jobs.append(saved)
                }
                state.saveSchedules(jobs)
            } onDelete: {
                state.saveSchedules(state.schedules.filter { $0.id != job.id })
            }
        }
    }

    @ViewBuilder
    private func scheduleRow(_ job: ScheduledJob) -> some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { job.enabled },
                    set: { newValue in
                        var updated = job
                        updated.enabled = newValue
                        var jobs = state.schedules
                        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                            jobs[idx] = updated
                        }
                        state.saveSchedules(jobs)
                    }
                )) {
                    Text(scheduleSummary(job)).fontWeight(.medium)
                }
                Spacer()
                Button {
                    editingSchedule = job
                    isNewSchedule = false
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit this schedule")
            }
            Text(job.categories.sorted(by: { $0.displayName < $1.displayName })
                    .map(\.displayName).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let next = job.nextRun {
                Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func scheduleSummary(_ job: ScheduledJob) -> String {
        let time = String(format: "%02d:00", job.hour)
        switch job.cadence {
        case .daily: return "Daily at \(time)"
        case .weekly:
            let symbols = Calendar.current.shortWeekdaySymbols
            let name = (job.weekday - 1 < symbols.count) ? symbols[job.weekday - 1] : "\(job.weekday)"
            return "Weekly \(name) at \(time)"
        case .monthly:
            return "Monthly on day \(job.dayOfMonth) at \(time)"
        }
    }

    // MARK: - AI key + connection helpers

    /// Refresh `storedKeyExists` for the currently-selected provider.
    private func refreshStoredKeyStatus() {
        storedKeyExists = KeychainHelper.load(for: state.aiConfig.provider) != nil
    }

    /// Loads the stored key into the input field so the user can view or
    /// re-save it. The field stays masked unless Reveal is on.
    private func fillFromKeychain() {
        if let key = KeychainHelper.load(for: state.aiConfig.provider) {
            apiKeyInput = key
            keyStatus = nil
        }
    }

    /// Saves the entered key to the Keychain, then verifies it with a cheap
    /// `testConnection` call against the provider. The advisor is a computed
    /// property that re-reads the Keychain, so the just-saved key is used.
    private func saveAndVerifyKey() async {
        let provider = state.aiConfig.provider
        do {
            try KeychainHelper.save(apiKeyInput, for: provider)
        } catch {
            keyStatus = "Failed to save key: \(error.localizedDescription)"
            keyStatusGood = false
            refreshStoredKeyStatus()
            return
        }
        refreshStoredKeyStatus()
        isVerifyingKey = true
        keyStatus = "Key saved — verifying with \(provider.displayName)…"
        keyStatusGood = true
        guard let advisor = state.advisor else {
            isVerifyingKey = false
            keyStatus = "Key saved, but no advisor is configured to verify it."
            keyStatusGood = false
            apiKeyInput = ""
            return
        }
        let result = await advisor.testConnection(config: state.aiConfig)
        isVerifyingKey = false
        apiKeyInput = ""
        if result.hasPrefix("Connected") {
            keyStatus = "Key saved and verified ✓ \(result)"
            keyStatusGood = true
        } else {
            keyStatus = "Key saved, but verification failed: \(result)"
            keyStatusGood = false
        }
    }

    private func removeKey() {
        let provider = state.aiConfig.provider
        do {
            try KeychainHelper.delete(for: provider)
            keyStatus = "Stored key removed."
            keyStatusGood = true
            apiKeyInput = ""
        } catch {
            keyStatus = "Failed to remove key: \(error.localizedDescription)"
            keyStatusGood = false
        }
        refreshStoredKeyStatus()
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

    // MARK: - Model field (Ollama picker when models are detected)

    @ViewBuilder
    private var modelField: some View {
        @Bindable var state = state
        let detected = ollamaDetection?.models ?? []
        if state.aiConfig.provider == .ollama, !detected.isEmpty {
            Picker("Model", selection: $state.aiConfig.model) {
                if state.aiConfig.model.isEmpty || !detected.contains(where: { $0.name == state.aiConfig.model }) {
                    Text(state.aiConfig.model.isEmpty ? "Pick a model" : state.aiConfig.model).tag(state.aiConfig.model)
                }
                ForEach(detected, id: \.name) { m in
                    Text(m.name).tag(m.name)
                }
            }
        } else {
            TextField("Model", text: $state.aiConfig.model, prompt: Text(state.aiConfig.provider.defaultModel))
                .autocorrectionDisabled()
        }
    }

    // MARK: - Ollama one-click (only when no provider is configured)

    @ViewBuilder
    private var ollamaOneClick: some View {
        if isDetectingOllama {
            HStack { ProgressView().controlSize(.small); Text("Looking for Ollama…") }
        } else if let detection = ollamaDetection, detection.isReachable, !detection.models.isEmpty {
            Button {
                state.aiConfig.provider = .ollama
                state.aiConfig.ollamaBaseURL = detection.baseURL
                state.aiConfig.model = detection.models.first?.name ?? ""
            } label: {
                Label("Use Ollama (local) — \(detection.models.count) model\(detection.models.count == 1 ? "" : "s") available", systemImage: "cpu")
            }
        } else if let detection = ollamaDetection, detection.didRespond, detection.models.isEmpty {
            Text("Ollama is running but has no models. Run `ollama pull llama3.2` in Terminal, then return here.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if ollamaDetection != nil {
            Text("Ollama not detected. Start it (`ollama serve` or the Ollama app) to use local AI.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshOllamaModels() {
        guard state.aiConfig.provider == .ollama || state.aiConfig.provider == .none else { return }
        isDetectingOllama = true
        let base = state.aiConfig.provider == .ollama ? state.aiConfig.ollamaBaseURL : nil
        Task {
            let detection = await OllamaDetector.detect(baseURL: base)
            await MainActor.run {
                ollamaDetection = detection
                isDetectingOllama = false
            }
        }
    }
}
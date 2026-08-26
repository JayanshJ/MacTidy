import SwiftUI
import AppKit
import CoreKit

/// Docker cleanup tab: shows disk usage, groups images by Compose project, and
/// lets the user remove whole projects, standalone images, or stopped
/// containers. All removals are irreversible (no Trash) and go through the
/// `DockerActionConfirmationSheet`.
struct DashboardDocker: View {
    @Environment(AppState.self) private var state
    @State private var dockerState: DockerState?
    @State private var availability: DockerScanner.Availability?
    @State private var isLoading = false
    @State private var dfTable: String?
    @State private var pendingActions: [any ShellAction] = []
    @State private var showSheet = false
    @State private var removeVolumes = false
    /// Set while we're waiting for Docker Desktop's daemon to come up after
    /// the user clicked "Open Docker". Drives the "Waiting for Docker…"
    /// state and re-runs `scan()` the moment `availability()` flips to
    /// `.available`, so the tab refreshes itself instead of staying stuck
    /// on the "Open Docker" button.
    @State private var waitingForDocker = false
    @State private var waitTask: Task<Void, Never>?
    /// Multi-select mode for containers. When on, each container row shows a
    /// checkbox and the toolbar exposes Select All / Select None / Remove
    /// Selected. Keyed by container id (stable across rescans).
    @State private var selectingContainers = false
    @State private var selectedContainerIDs: Set<String> = []
    /// Best-effort reclaimable bytes in the Docker BuildKit cache, from
    /// `docker builder df`. Drives the "Prune builder cache" card. Nil until
    /// the first scan reads it (or if Docker is unavailable).
    @State private var builderCacheBytes: Int64?
    @State private var showBuilderPruneSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showSheet) {
            DockerActionConfirmationSheet(
                actions: pendingActions,
                removeVolumes: $removeVolumes,
                onCompleted: {
                    // Batch removal just ran — clear the selection and rescan.
                    selectedContainerIDs.removeAll()
                    selectingContainers = false
                    Task { await scan() }
                }
            )
        }
        .sheet(isPresented: $showBuilderPruneSheet) {
            ShellActionConfirmationSheet(
                title: "Prune the Docker builder cache?",
                actions: [DockerBuilderPruneAction(estimatedBytes: builderCacheBytes ?? 0)],
                kind: .dockerBuilderCache,
                note: "This clears BuildKit's layer/build cache with `docker builder prune -f`. It does not remove images or containers, and the cache rebuilds on demand. This cannot be undone.",
                onCompleted: { Task { await scan() } }
            )
        }
        .task { if availability == nil { await scan() } }
        // Catch the case where Docker was started from Spotlight/Finder
        // while the app was in the background: re-check availability when
        // the user returns to the app, and refresh the list if it's now up.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !waitingForDocker, availability != .available else { return }
            Task { await scan() }
        }
        .onDisappear { waitTask?.cancel() }
    }

    private var header: some View {
        HStack {
            Text("Docker").font(.title3.bold())
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            // Toggle multi-select for containers. Only meaningful when there
            // are containers to select; hidden otherwise so the header stays
            // clean for image-only / empty states.
            if dockerState?.containers.isEmpty == false {
                Button {
                    selectingContainers.toggle()
                    if !selectingContainers { selectedContainerIDs.removeAll() }
                } label: {
                    Label(selectingContainers ? "Done" : "Select",
                          systemImage: selectingContainers ? "checkmark.circle" : "checkmark.circle.fill")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Select multiple containers to remove at once.")
            }
            Button { Task { await scan() } } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && dockerState == nil {
            ProgressView("Scanning Docker…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if availability == .notInstalled {
            ContentUnavailableView("Docker isn't installed",
                systemImage: "cylinder.split.1x2",
                description: Text("Install Docker Desktop to reclaim space from images and containers."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if availability == .notRunning {
            VStack(spacing: Theme.Spacing.md) {
                if waitingForDocker {
                    ProgressView("Waiting for Docker to start…")
                        .controlSize(.large)
                    Text("Docker Desktop's daemon can take a while to be ready. This will refresh automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    ContentUnavailableView("Docker is not running",
                        systemImage: "power.circle",
                        description: Text("Start Docker Desktop, then rescan."))
                    Button("Open Docker") { openDocker() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let ds = dockerState {
            dockerList(ds)
        } else {
            ContentUnavailableView("No Docker data",
                systemImage: "cylinder.split.1x2",
                description: Text("Docker reports no images or containers."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func dockerList(_ ds: DockerState) -> some View {
        VStack(spacing: 0) {
            if selectingContainers, !ds.containers.isEmpty {
                containerSelectionBar(ds)
            }
            List {
                if let df = dfTable, !df.isEmpty {
                DisclosureGroup("Docker disk usage (raw)") {
                    Text(df).font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            builderCacheRow
            if !ds.projects.isEmpty {
                Section("Compose projects (\(ds.projects.count))") {
                    ForEach(ds.projects) { project in
                        dockerProjectRow(project)
                    }
                }
            }
            if !ds.standaloneImages.isEmpty {
                Section("Standalone images (\(ds.standaloneImages.count))") {
                    ForEach(ds.standaloneImages) { img in
                        dockerImageRow(img)
                    }
                }
            }
            if !ds.containers.isEmpty {
                let running = ds.containers.filter { $0.running }
                let stopped = ds.containers.filter { !$0.running }
                if !running.isEmpty {
                    Section("Running containers (\(running.count))") {
                        ForEach(running) { c in
                            dockerContainerRow(c)
                        }
                    }
                }
                if !stopped.isEmpty {
                    Section("Stopped containers (\(stopped.count))") {
                        ForEach(stopped) { c in
                            dockerContainerRow(c)
                        }
                    }
                }
            }
        }
        }
        .listStyle(.inset)
    }

    /// The BuildKit (builder) cache reclaim card. `docker builder prune -f`
    /// clears layer/build cache that rebuilds on demand — distinct from
    /// images/containers (handled above) and from `docker system prune`
    /// (which MacTidy never runs). Manual-only; the sheet shows the literal
    /// command and the "cannot be undone" warning.
    @ViewBuilder
    private var builderCacheRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "hammer.drill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Builder cache (BuildKit)").font(.callout.weight(.medium))
                Text(builderCacheLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Prune") {
                showBuilderPruneSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Clear Docker's build cache. It rebuilds on demand. This does not remove images or containers.")
        }
        .padding(.vertical, 4)
    }

    private var builderCacheLabel: String {
        if let bytes = builderCacheBytes, bytes > 0 {
            return "~\(bytes.formattedBytes) reclaimable — rebuilds on demand."
        }
        return "Reclaimable size unknown — the cache rebuilds on demand."
    }

    /// The multi-select action bar: Select All / None + a Remove Selected
    /// button that batches the chosen containers into one confirmation sheet.
    /// Shown only while `selectingContainers` is on.
    @ViewBuilder
    private func containerSelectionBar(_ ds: DockerState) -> some View {
        let allIDs = Set(ds.containers.map(\.id))
        let allSelected = selectedContainerIDs.count == allIDs.count && !allIDs.isEmpty
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                if allSelected {
                    selectedContainerIDs.removeAll()
                } else {
                    selectedContainerIDs = allIDs
                }
            } label: {
                Label(allSelected ? "Deselect All" : "Select All",
                      systemImage: allSelected ? "circle" : "checkmark.circle.fill")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(allIDs.isEmpty)

            Text("\(selectedContainerIDs.count) selected")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            Spacer()

            Button {
                removeSelectedContainers(ds)
            } label: {
                Label("Remove Selected", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .tint(.red)
            .disabled(selectedContainerIDs.isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.xs)
        .background(.separator.opacity(0.35))
    }

    private func removeSelectedContainers(_ ds: DockerState) {
        let chosen = ds.containers.filter { selectedContainerIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        pendingActions = chosen.map { DockerContainerRemoveAction(container: $0) }
        showSheet = true
    }

    @ViewBuilder
    private func dockerProjectRow(_ project: DockerComposeProject) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).fontWeight(.medium)
                Text("\(project.images.count) image(s) · ≈ \(project.totalBytes.formattedBytes)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Badge(text: project.running ? "running" : "stopped",
                  tint: project.running ? Theme.Status.good : Theme.Status.caution)
            Button {
                pendingActions = [DockerComposeDownAction(project: project, removeVolumes: removeVolumes)]
                showSheet = true
            } label: {
                Label("Remove project", systemImage: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    @ViewBuilder
    private func dockerImageRow(_ img: DockerImage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(img.dangling ? "dangling" : "\(img.repository):\(img.tag)").fontWeight(.medium)
                Text("\(img.id.prefix(19)) · \(img.sizeBytes.formattedBytes) · \(img.createdSince)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            // Heuristic attribution for non-compose images: "likely <project>"
            // when a container's working dir / bind mounts resolved to a name,
            // "in use" when a running container references it, and "orphaned"
            // when no container references it at all (safe to prune). The
            // guess is honest about being a guess.
            if let attr = dockerState?.attribution(for: img) {
                if let project = attr.projectGuess {
                    Badge(text: "likely \(project)", tint: Theme.Status.caution)
                        .help("A container referencing this image appears to belong to \(project) — inferred from its working directory or bind mounts. Not a certainty.")
                }
                if attr.inUse {
                    Badge(text: "in use", tint: Theme.Status.good)
                        .help("A running container references this image.")
                }
            } else if dockerState != nil {
                Badge(text: "orphaned", tint: .secondary)
                    .help("No container references this image. Safe to remove unless you're about to run it.")
            }
            Button {
                pendingActions = [DockerImageRemoveAction(image: img)]
                showSheet = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    @ViewBuilder
    private func dockerContainerRow(_ c: DockerContainer) -> some View {
        HStack {
            if selectingContainers {
            Button {
                toggleContainer(c)
            } label: {
                Image(systemName: selectedContainerIDs.contains(c.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedContainerIDs.contains(c.id)
                                     ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help("Select this container for batch removal.")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).fontWeight(.medium)
                Text("image \(c.image)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Badge(text: c.running ? "running" : "stopped",
                  tint: c.running ? Theme.Status.good : Theme.Status.caution)
            if !selectingContainers {
                Button {
                    pendingActions = [DockerContainerRemoveAction(container: c)]
                    showSheet = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help(c.running ? "Stops then removes the container (docker rm -f)." : "Removes the stopped container.")
            }
        }
    }

    private func toggleContainer(_ c: DockerContainer) {
        if selectedContainerIDs.contains(c.id) {
            selectedContainerIDs.remove(c.id)
        } else {
            selectedContainerIDs.insert(c.id)
        }
    }

    private func scan() async {
        isLoading = true
        let avail = DockerScanner.availability()
        availability = avail
        if avail == .available {
            dockerState = DockerScanner.scan()
            dfTable = DockerScanner.systemDFTable()
            builderCacheBytes = DockerBuilderCache.reclaimableBytes()
            // Drop selections for containers that no longer exist after the
            // rescan (e.g. removed out-of-band or by a prior cleanup).
            if let ds = dockerState {
                let live = Set(ds.containers.map(\.id))
                selectedContainerIDs = selectedContainerIDs.intersection(live)
            }
        } else {
            dockerState = nil
        }
        isLoading = false
    }

    private func openDocker() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
        // Launching the app isn't enough — Docker Desktop's daemon takes
        // tens of seconds to accept commands. Poll `availability()` until
        // it's ready (or we time out), then run a real scan so the tab
        // transitions to the image/container list without a manual Rescan.
        waitTask?.cancel()
        waitingForDocker = true
        waitTask = Task {
            let deadline = 90_000_000_000  // 90s — Docker Desktop is slow.
            let start = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                if DockerScanner.availability() == .available {
                    await scan()
                    break
                }
                if DispatchTime.now().uptimeNanoseconds - start > deadline { break }
                try? await Task.sleep(for: .seconds(2))
            }
            await MainActor.run { waitingForDocker = false }
        }
    }
}

/// Confirmation sheet for shell-based destructive actions. Mirrors
/// `DeletionConfirmationSheet` but: (1) shows the literal docker command per
/// action, (2) a red no-undo banner, (3) the volume opt-in checkbox for
/// compose-down actions. Outcome lists succeeded/failed with real stderr.
struct DockerActionConfirmationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let actions: [any ShellAction]
    @Binding var removeVolumes: Bool
    @State private var outcome: ShellActionOutcome?
    var onCompleted: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome { outcomeView(outcome) } else { planView }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private var planView: some View {
        Text("Docker cleanup").font(.title2.bold())
        Label("This cannot be undone — Docker does not go through the Trash.",
              systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout.weight(.medium))

        if hasComposeDown {
            Toggle("Also remove named volumes (deletes database data)", isOn: $removeVolumes)
                .tint(.red)
        }

        List {
            Section("Commands (\(actions.count))") {
                ForEach(actions, id: \.id) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.displayName).fontWeight(.medium)
                        Text(action.commandSummary)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .listStyle(.bordered)
        .frame(maxHeight: .infinity)

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Run") { execute() }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
                .disabled(actions.isEmpty)
        }
    }

    private var hasComposeDown: Bool {
        actions.contains { $0 is DockerComposeDownAction }
    }

    private func execute() {
        var toRun = actions
        // Rebuild compose-down actions with the current removeVolumes toggle.
        toRun = toRun.map { action in
            if let cd = action as? DockerComposeDownAction {
                return DockerComposeDownAction(project: cd.project, removeVolumes: removeVolumes)
                    as any ShellAction
            }
            return action
        }
        outcome = state.executeShellActions(toRun, kind: .docker)
    }

    @ViewBuilder
    private func outcomeView(_ outcome: ShellActionOutcome) -> some View {
        Label("Ran \(outcome.succeeded.count) action(s) · ≈ \(outcome.reclaimedBytes.formattedBytes)",
              systemImage: "checkmark.circle")
            .font(.title2.bold())
        List {
            if !outcome.succeeded.isEmpty {
                Section("Succeeded") {
                    ForEach(outcome.succeeded, id: \.id) { a in
                        Label(a.displayName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Status.good)
                    }
                }
            }
            if !outcome.failed.isEmpty {
                Section("Failed") {
                    ForEach(outcome.failed) { f in
                        VStack(alignment: .leading) {
                            Text(f.action.displayName).fontWeight(.medium)
                            Text(f.message).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .listStyle(.bordered)
        .frame(maxHeight: .infinity)
        HStack {
            Spacer()
            Button("Done") { onCompleted(); dismiss() }.keyboardShortcut(.defaultAction)
        }
    }
}
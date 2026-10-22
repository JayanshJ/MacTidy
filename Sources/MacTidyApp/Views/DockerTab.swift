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
    @State private var sheetTrigger: SheetTrigger?
    @State private var builderPruneTrigger: BuilderPruneTrigger?
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

    var body: some View {
        Page("Docker",
             subtitle: "Images, containers and build cache. Removing runs docker commands directly, so it can't be undone from the Trash.") {
            if isLoading { ProgressView().controlSize(.small) }
            if dockerState?.containers.isEmpty == false {
                Button(selectingContainers ? "Done" : "Select Containers") {
                    selectingContainers.toggle()
                    if !selectingContainers { selectedContainerIDs.removeAll() }
                }
            }
            Button { Task { await scan() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        } content: {
            content
        }
        .sheet(item: $sheetTrigger) { trigger in
            DockerActionConfirmationSheet(
                actions: trigger.actions,
                removeVolumes: $removeVolumes,
                onCompleted: {
                    // Batch removal just ran — clear the selection and rescan.
                    selectedContainerIDs.removeAll()
                    selectingContainers = false
                    sheetTrigger = nil
                    Task { await scan() }
                }
            )
        }
        .sheet(item: $builderPruneTrigger) { _ in
            ShellActionConfirmationSheet(
                title: "Prune the Docker builder cache?",
                actions: [DockerBuilderPruneAction(estimatedBytes: builderCacheBytes ?? 0)],
                kind: .dockerBuilderCache,
                note: "This clears BuildKit's layer/build cache with `docker builder prune -f`. It does not remove images or containers, and the cache rebuilds on demand. This cannot be undone.",
                onCompleted: { Task { await scan() } }
            )
        }
        .task {
            // Use preloaded data from AppState if available (loaded during
            // startFlow), so the tab appears instantly without re-scanning.
            if let avail = state.dockerAvailability {
                availability = avail
                dockerState = state.dockerState
                dfTable = state.dockerDfTable
                builderCacheBytes = state.dockerBuilderCacheBytes
            } else if availability == nil {
                await scan()
            }
        }
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

    @ViewBuilder
    private var content: some View {
        if isLoading && dockerState == nil {
            ProgressView("Asking Docker").frame(maxWidth: .infinity).padding(Theme.Spacing.xxl)
        } else if availability == .notInstalled {
            EmptyStateView(symbol: "shippingbox", title: "Docker isn't installed",
                           message: "When Docker Desktop, OrbStack or Colima is installed, its images and containers show up here.")
        } else if availability == .notRunning {
            if waitingForDocker {
                VStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                    Text("Waiting for Docker to start. This refreshes on its own.")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(Theme.Spacing.xxl)
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    EmptyStateView(symbol: "power", title: "Docker isn't running",
                                   message: "Start Docker to see what its images and containers take up.")
                    Button("Open Docker") { openDocker() }.buttonStyle(.borderedProminent)
                }
            }
        } else if let ds = dockerState {
            dockerList(ds)
        } else {
            EmptyStateView(symbol: "shippingbox", title: "Nothing in Docker",
                           message: "No images or containers right now.")
        }
    }

    @ViewBuilder
    private func dockerList(_ ds: DockerState) -> some View {
        if selectingContainers, !ds.containers.isEmpty {
            containerSelectionBar(ds)
        }
        SurfaceSection("Build cache") {
            builderCacheRow
        }
        if !ds.projects.isEmpty {
            SurfaceSection("Compose projects") {
                ForEach(Array(ds.projects.enumerated()), id: \.element.id) { i, project in
                    if i > 0 { RowDivider() }
                    dockerProjectRow(project)
                }
            }
        }
        if !ds.standaloneImages.isEmpty {
            SurfaceSection("Images") {
                ForEach(Array(ds.standaloneImages.enumerated()), id: \.element.id) { i, img in
                    if i > 0 { RowDivider() }
                    dockerImageRow(img)
                }
            }
        }
        let running = ds.containers.filter { $0.running }
        let stopped = ds.containers.filter { !$0.running }
        if !running.isEmpty {
            SurfaceSection("Running containers") {
                ForEach(Array(running.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { RowDivider() }
                    dockerContainerRow(c)
                }
            }
        }
        if !stopped.isEmpty {
            SurfaceSection("Stopped containers") {
                ForEach(Array(stopped.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { RowDivider() }
                    dockerContainerRow(c)
                }
            }
        }
        if let df = dfTable, !df.isEmpty {
            DisclosureGroup("Raw docker system df") {
                Text(df)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Spacing.sm)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var builderCacheRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BuildKit cache").font(Theme.Font.bodyStrong)
                Text("Layers kept to speed up builds. Rebuilds on demand; images and containers stay.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let bytes = builderCacheBytes, bytes > 0 {
                Text(bytes.formattedBytes).font(Theme.Font.bodyStrong.monospacedDigit())
            }
            Button("Prune…") { builderPruneTrigger = BuilderPruneTrigger() }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    @ViewBuilder
    private func containerSelectionBar(_ ds: DockerState) -> some View {
        let allIDs = Set(ds.containers.map(\.id))
        let allSelected = selectedContainerIDs.count == allIDs.count && !allIDs.isEmpty
        HStack(spacing: Theme.Spacing.md) {
            Button(allSelected ? "Deselect All" : "Select All") {
                selectedContainerIDs = allSelected ? [] : allIDs
            }
            .disabled(allIDs.isEmpty)
            Text("\(selectedContainerIDs.count) selected")
                .font(Theme.Font.body.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button("Remove Selected…") { removeSelectedContainers(ds) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Status.blocked)
                .disabled(selectedContainerIDs.isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .cardStyle(padded: false)
    }

    private func removeSelectedContainers(_ ds: DockerState) {
        let chosen = ds.containers.filter { selectedContainerIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        sheetTrigger = SheetTrigger(actions: chosen.map { DockerContainerRemoveAction(container: $0) })
    }

    private func statusDot(_ running: Bool) -> some View {
        Circle().fill(running ? Theme.accent : Theme.track).frame(width: 7, height: 7)
            .help(running ? "Running" : "Stopped")
    }

    private func dockerProjectRow(_ project: DockerComposeProject) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            statusDot(project.running)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(Theme.Font.bodyStrong)
                Text("\(project.images.count) image\(project.images.count == 1 ? "" : "s")")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(project.totalBytes.formattedBytes).font(Theme.Font.body.monospacedDigit()).foregroundStyle(.secondary)
            Button("Remove…") {
                sheetTrigger = SheetTrigger(actions: [DockerComposeDownAction(project: project, removeVolumes: removeVolumes)])
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func dockerImageRow(_ img: DockerImage) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(img.dangling ? "Untagged image" : "\(img.repository):\(img.tag)")
                        .font(Theme.Font.bodyStrong).lineLimit(1)
                    // Heuristic attribution; labelled as a guess.
                    if let attr = dockerState?.attribution(for: img) {
                        if let project = attr.projectGuess {
                            Badge(text: "likely \(project)", tint: .secondary)
                                .help("Inferred from a container's working directory or mounts. Not certain.")
                        }
                        if attr.inUse { Badge(text: "In use", tint: Theme.accent) }
                    } else if dockerState != nil {
                        Badge(text: "Unused", tint: Theme.Status.caution)
                            .help("No container uses this image.")
                    }
                }
                Text("\(img.id.prefix(12))  ·  \(img.createdSince)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(img.sizeBytes.formattedBytes).font(Theme.Font.body.monospacedDigit()).foregroundStyle(.secondary)
            Button("Remove…") { sheetTrigger = SheetTrigger(actions: [DockerImageRemoveAction(image: img)]) }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func dockerContainerRow(_ c: DockerContainer) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            if selectingContainers {
                Toggle("", isOn: Binding(get: { selectedContainerIDs.contains(c.id) },
                                         set: { _ in toggleContainer(c) }))
                    .toggleStyle(.checkbox).labelsHidden()
            }
            statusDot(c.running)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(Theme.Font.bodyStrong)
                Text(c.image).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if !selectingContainers {
                Button("Remove…") { sheetTrigger = SheetTrigger(actions: [DockerContainerRemoveAction(container: c)]) }
                    .help(c.running ? "Stops, then removes the container." : "Removes the stopped container.")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
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
        .padding(Theme.Spacing.xl)
        .frame(width: 560, height: 480)
        .background(Theme.canvas)
    }

    @ViewBuilder
    private var planView: some View {
        Text("Docker cleanup").font(.system(size: 17, weight: .semibold))
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
                .buttonStyle(.borderedProminent)
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
            .font(.system(size: 17, weight: .semibold))
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
            Button("Done") { onCompleted(); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }
}

/// Identifiable wrapper for the Docker action sheet. Using `.sheet(item:)`
/// instead of `.sheet(isPresented:)` + a separate state variable avoids the
/// race where the sheet's content closure captures stale (empty) actions
/// when both are set in the same render cycle.
struct SheetTrigger: Identifiable {
    let id = UUID()
    let actions: [any ShellAction]
}

/// Trigger for the builder-prune sheet (no payload needed — the action is
/// built from `builderCacheBytes` at sheet-creation time). Exists only to
/// drive `.sheet(item:)` instead of `.sheet(isPresented:)`.
struct BuilderPruneTrigger: Identifiable {
    let id = UUID()
}
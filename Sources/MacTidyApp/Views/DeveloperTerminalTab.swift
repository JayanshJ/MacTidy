import SwiftUI
import CoreKit

/// Developer Terminal tab on the dashboard. Styled like a real terminal —
/// dark background, monospaced fonts, colorized port labels — because the
/// user wants a developer-focused tool that feels like home, not a generic
/// settings panel.
///
/// Four sections:
/// 1. **Ports & Processes** — every TCP listening port, colorized by runtime
///    (Node=green, Python=yellow, Java=orange, Docker=blue, Database=purple,
///    Other=gray). Per-port Kill button (SIGTERM).
/// 2. **Package Manager Caches** — npm/yarn/pnpm/brew/cargo/simctl cache sizes
///    with one-click clean actions.
/// 3. **Docker Volumes** — prunes unused Docker volumes.
/// 4. **System** — Time Machine local snapshots (merged from the former System
///    tab so all shell-action cleanup lives in one place).
///
/// All destructive actions are `ShellAction`s routed through
/// `ShellActionConfirmationSheet` — irreversible, command shown verbatim.
struct DeveloperTerminalTab: View {
    @Environment(AppState.self) private var state
    @State private var ports: [PortEntry] = []
    @State private var devTools: [DevToolInfo] = []
    @State private var isLoading = false
    /// Drives the action sheet via `.sheet(item:)` — avoids the race where
    /// `.sheet(isPresented:)` captures stale state (the "small rounded square"
    /// bug). The trigger carries everything the sheet needs.
    @State private var actionTrigger: DevActionTrigger?
    @State private var infoEntry: PortEntry?

    @State private var dockerAvailable = false

    var body: some View {
        Page("Dev Tools",
             subtitle: "What's listening on your ports, and the caches your package managers keep. These run real commands, so they skip the Trash.") {
            if isLoading { ProgressView().controlSize(.small) }
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        } content: {
            portsSection
            cachesSection
            if dockerAvailable { dockerVolumeSection }
        }
        .sheet(item: $actionTrigger) { trigger in
            ShellActionConfirmationSheet(
                title: trigger.title,
                actions: trigger.actions,
                kind: trigger.kind,
                note: trigger.note,
                onCompleted: { Task { await load() } }
            )
        }
        .sheet(item: $infoEntry) { entry in
            PortInfoSheet(entry: entry) { infoEntry = nil }
        }
        .task {
            if !state.devPorts.isEmpty || !state.devTools.isEmpty {
                ports = state.devPorts
                devTools = state.devTools
                dockerAvailable = state.dockerAvailability == .available
            } else {
                await load()
            }
        }
        .task(id: "auto-refresh") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
    }

    // MARK: - Ports

    @ViewBuilder
    private var portsSection: some View {
        SurfaceSection("Listening ports") {
            if !ports.isEmpty {
                Text("\(ports.count)").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } content: {
            if isLoading && ports.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(Theme.Spacing.lg)
            } else if ports.isEmpty {
                Text("Nothing is listening.").font(Theme.Font.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Spacing.lg)
            } else {
                portHeader
                ForEach(Array(ports.enumerated()), id: \.element.id) { i, entry in
                    RowDivider(inset: 0)
                    portRow(entry)
                }
            }
        }
    }

    private var portHeader: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("Port").frame(width: 64, alignment: .leading)
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("Runtime").frame(width: 96, alignment: .leading)
            Text("Address").frame(width: 92, alignment: .leading)
            Spacer().frame(width: 92)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func portRow(_ entry: PortEntry) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(verbatim: "\(entry.port)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.processName).font(Theme.Font.bodyStrong).lineLimit(1)
                Text(verbatim: "PID \(entry.pid)" + (entry.lsofCommand != entry.processName && !entry.lsofCommand.isEmpty ? "  ·  \(entry.lsofCommand)" : ""))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Circle().fill(entry.devRuntime == .other ? Theme.track : runtimeColor(entry.devRuntime))
                    .frame(width: 7, height: 7)
                Text(entry.devRuntime.displayName).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)
            Text(entry.bindAddress)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            HStack(spacing: Theme.Spacing.xs) {
                if !entry.explanation.isEmpty {
                    Button { infoEntry = entry } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("What is this?")
                }
                Button("Stop…") {
                    actionTrigger = DevActionTrigger(
                        title: "Stop \(entry.processName)?",
                        actions: [KillProcessAction(pid: entry.pid, name: entry.processName, port: entry.port)],
                        kind: .devTerminal, note: nil)
                }
                .controlSize(.small)
                .help("Sends SIGTERM so the process can shut down cleanly.")
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    /// Runtime dots: a few muted hues so common stacks are tellable apart.
    private func runtimeColor(_ runtime: DevRuntime) -> Color {
        switch runtime {
        case .node: Theme.accent
        case .python: .yellow
        case .java, .ruby: .orange
        case .go, .webserver: .teal
        case .php, .dotnet, .database: .indigo
        case .docker: .blue
        case .other: .gray
        }
    }

    // MARK: - Package caches

    @ViewBuilder
    private var cachesSection: some View {
        let total = devTools.reduce(Int64(0)) { $0 + $1.cacheBytes }
        SurfaceSection("Package manager caches", footer: "Cleaned through each tool's own command. Packages download again when a project needs them.") {
            if !devTools.isEmpty {
                Button("Clean All (\(total.formattedBytes))…") {
                    actionTrigger = DevActionTrigger(
                        title: "Clean all developer caches?",
                        actions: devTools.compactMap { actionForTool($0) },
                        kind: .devTerminal, note: nil)
                }
                .buttonStyle(.link)
                .font(Theme.Font.caption)
            }
        } content: {
            if isLoading && devTools.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(Theme.Spacing.lg)
            } else if devTools.isEmpty {
                Text("No package manager caches found.").font(Theme.Font.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Spacing.lg)
            } else {
                ForEach(Array(devTools.enumerated()), id: \.element.id) { i, info in
                    if i > 0 { RowDivider(inset: 48) }
                    cacheRow(info)
                }
            }
        }
    }

    private func cacheRow(_ info: DevToolInfo) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: info.tool.icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(info.tool.displayName).font(Theme.Font.bodyStrong)
                    if let v = info.version {
                        Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                Text(info.tool.cleanDescription).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.lg)
            if info.tool == .simctl, info.simctlUnavailableCount > 0 {
                Text("\(info.simctlUnavailableCount) unavailable").font(Theme.Font.body).foregroundStyle(Theme.Status.caution)
            } else {
                Text(info.cacheBytes.formattedBytes).font(Theme.Font.bodyStrong.monospacedDigit())
            }
            Button("Clean…") { cleanTool(info) }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Docker volumes

    private var dockerVolumeSection: some View {
        SurfaceSection("Docker") {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "externaldrive").foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unused volumes").font(Theme.Font.bodyStrong)
                    Text("Volumes no container refers to. Their data is deleted for good.")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Prune…") {
                    actionTrigger = DevActionTrigger(
                        title: "Prune unused Docker volumes?",
                        actions: [DockerVolumePruneAction()],
                        kind: .devTerminal, note: nil)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    // MARK: - Actions

    private func cleanTool(_ info: DevToolInfo) {
        guard let action = actionForTool(info) else { return }
        actionTrigger = DevActionTrigger(
            title: "Clean \(info.tool.displayName)?",
            actions: [action],
            kind: .devTerminal, note: nil)
    }

    private func actionForTool(_ info: DevToolInfo) -> (any ShellAction)? {
        switch info.tool {
        case .npm: return NpmCacheCleanAction(estimatedBytes: info.cacheBytes)
        case .yarn: return YarnCacheCleanAction(estimatedBytes: info.cacheBytes)
        case .pnpm: return PnpmStorePruneAction(estimatedBytes: info.cacheBytes)
        case .brew: return BrewCleanupAction(estimatedBytes: info.cacheBytes)
        case .cargo: return CargoCacheCleanAction(estimatedBytes: info.cacheBytes)
        case .simctl: return SimctlDeleteUnavailableAction(unavailableCount: info.simctlUnavailableCount)
        }
    }

    private func load() async {
        isLoading = true
        async let portScan = Task.detached { PortScanner.scan() }.value
        async let toolScan = DevToolScanner.scan()
        async let docker = Task.detached { DockerScanner.availability() == .available }.value
        let (p, t, d) = await (portScan, toolScan, docker)
        ports = p
        devTools = t
        dockerAvailable = d
        isLoading = false
    }
}

/// A plain-language explanation sheet for a port's process. Shows what the
/// process is, whether it's safe to kill, and the technical details (PID,
/// port, runtime) in a compact, readable card.
struct PortInfoSheet: View {
    let entry: PortEntry
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header: runtime icon + process name + port.
            HStack(spacing: 12) {
                Image(systemName: entry.devRuntime.icon)
                    .font(.title2)
                    .foregroundStyle(runtimeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.processName)
                        .font(.title3.monospaced().bold())
                    Text(":\(entry.port) · \(entry.devRuntime.displayName)")
                        .font(.callout.monospaced())
                        .foregroundStyle(runtimeColor)
                }
                Spacer()
            }

            Divider()

            // The plain-language explanation.
            if !entry.explanation.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What is this?")
                        .font(.headline)
                    Text(entry.explanation)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Technical details.
            VStack(alignment: .leading, spacing: 4) {
                Text("Details").font(.caption.bold()).foregroundStyle(.secondary)
                detailRow("PID", "\(entry.pid)")
                detailRow("Port", ":\(entry.port)")
                detailRow("Bind", entry.bindAddress)
                detailRow("Runtime", entry.devRuntime.displayName)
                if entry.lsofCommand != entry.processName && !entry.lsofCommand.isEmpty {
                    detailRow("lsof name", entry.lsofCommand)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 360)
    }

    private var runtimeColor: Color {
        switch entry.devRuntime {
        case .node: .green
        case .python: .yellow
        case .java: .orange
        case .ruby: .red
        case .go: .cyan
        case .php: .indigo
        case .dotnet: .purple
        case .webserver: .teal
        case .docker: .blue
        case .database: .purple
        case .other: .gray
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// Identifiable trigger for the Dev Terminal action sheet. Using `.sheet(item:)`
/// avoids the race where `.sheet(isPresented:)` captures stale state — the
/// "small rounded square window" bug that requires Escape + re-click.
struct DevActionTrigger: Identifiable {
    let id = UUID()
    let title: String
    let actions: [any ShellAction]
    let kind: CleanupEntry.Kind
    let note: String?
}
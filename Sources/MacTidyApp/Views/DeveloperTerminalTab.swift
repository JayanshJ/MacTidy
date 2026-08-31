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
    @State private var snapshots: [TMSnapshot] = []
    @State private var isLoading = false
    /// Drives the action sheet via `.sheet(item:)` — avoids the race where
    /// `.sheet(isPresented:)` captures stale state (the "small rounded square"
    /// bug). The trigger carries everything the sheet needs.
    @State private var actionTrigger: DevActionTrigger?
    @State private var infoEntry: PortEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    portsSection
                    cachesSection
                    dockerVolumeSection
                    systemSection
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            // Use preloaded data from AppState if available (loaded during
            // startFlow), so the tab appears instantly without re-scanning.
            if !state.devPorts.isEmpty || !state.devTools.isEmpty || !state.devSnapshots.isEmpty {
                ports = state.devPorts
                devTools = state.devTools
                snapshots = state.devSnapshots
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

    // MARK: - Header (terminal-style title bar)

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Terminal traffic-light dots.
            HStack(spacing: 6) {
                Circle().fill(Color.red.opacity(0.7)).frame(width: 11, height: 11)
                Circle().fill(Color.yellow.opacity(0.7)).frame(width: 11, height: 11)
                Circle().fill(Color.green.opacity(0.7)).frame(width: 11, height: 11)
            }
            Text("developer-terminal")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Button { Task { await load() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Ports & Processes (terminal table)

    @ViewBuilder
    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header bar.
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.callout.monospaced())
                Text("$ lsof -iTCP -sTCP:LISTEN -P -n")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if !ports.isEmpty {
                    Text("\(ports.count) listening")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.black.opacity(0.06))

            if isLoading && ports.isEmpty {
                HStack { Spacer(); ProgressView("Scanning ports…"); Spacer() }
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if ports.isEmpty {
                Text("● No listening ports found.")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                // Terminal-style table: monospaced columns, colorized by runtime.
                portTable
            }
        }
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var portTable: some View {
        VStack(spacing: 0) {
            // Column headers.
            HStack(spacing: 0) {
                portColumnHeader("PROTO", width: 50)
                portColumnHeader("PORT", width: 70)
                portColumnHeader("BIND", width: 110)
                portColumnHeader("PID", width: 60)
                portColumnHeader("PROCESS", width: nil)
                portColumnHeader("RUNTIME", width: 90)
                portColumnHeader("", width: 80)
            }
            .font(.caption2.monospaced().bold())
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.04))

            Divider()

            // Rows.
            ForEach(Array(ports.enumerated()), id: \.element.id) { idx, entry in
                portRow(entry, isOdd: idx % 2 == 1)
            }
        }
    }

    @ViewBuilder
    private func portRow(_ entry: PortEntry, isOdd: Bool) -> some View {
        HStack(spacing: 0) {
            // PROTO
            portCell("TCP", width: 50, color: .secondary)
            // PORT (highlighted in runtime color)
            portCell(":\(entry.port)", width: 70, color: runtimeColor(entry.devRuntime), bold: true)
            // BIND
            portCell(entry.bindAddress, width: 110, color: .tertiary)
            // PID
            portCell("\(entry.pid)", width: 60, color: .secondary)
            // PROCESS (may be truncated lsof name or attributed app name)
            HStack(spacing: 4) {
                Text(entry.processName)
                    .lineLimit(1).truncationMode(.tail)
                if entry.lsofCommand != entry.processName
                    && !entry.lsofCommand.isEmpty {
                    Text("(\(entry.lsofCommand))")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            // RUNTIME badge
            HStack(spacing: 4) {
                Circle()
                    .fill(runtimeColor(entry.devRuntime))
                    .frame(width: 7, height: 7)
                Text(entry.devRuntime.displayName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(runtimeColor(entry.devRuntime))
            }
            .frame(width: 90, alignment: .leading)
            .padding(.horizontal, 8)
            // INFO + KILL buttons
            HStack(spacing: 4) {
                if !entry.explanation.isEmpty {
                    Button {
                        infoEntry = entry
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("What is this?")
                }
                Button("kill") {
                    actionTrigger = DevActionTrigger(
                        title: "Kill process?",
                        actions: [KillProcessAction(pid: entry.pid, name: entry.processName, port: entry.port)],
                        kind: .devTerminal, note: nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .font(.caption.monospaced())
            }
            .frame(width: 80)
        }
        .padding(.vertical, 3)
        .background(isOdd ? Color.black.opacity(0.02) : Color.clear)

        Divider().opacity(0.3)
    }

    private func portColumnHeader(_ text: String, width: CGFloat?) -> some View {
        Group {
            if let width {
                Text(text)
                    .frame(width: width, alignment: .leading)
            } else {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
    }

    private func portCell(_ text: String, width: CGFloat, color: some ShapeStyle, bold: Bool = false) -> some View {
        Text(text)
            .font(.callout.monospaced().weight(bold ? .bold : .regular))
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
    }

    /// Maps a `DevRuntime` to a SwiftUI Color for terminal-style coloring.
    private func runtimeColor(_ runtime: DevRuntime) -> Color {
        switch runtime {
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

    // MARK: - Package Manager Caches

    @ViewBuilder
    private var cachesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header bar.
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.callout.monospaced())
                Text("$ du -sh ~/.npm ~/.cargo ~/.gradle ...")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if !devTools.isEmpty {
                    let total = devTools.reduce(Int64(0)) { $0 + $1.cacheBytes }
                    Text("total: \(total.formattedBytes)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.black.opacity(0.06))

            if isLoading && devTools.isEmpty {
                HStack { Spacer(); ProgressView("Scanning caches…"); Spacer() }
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if devTools.isEmpty {
                Text("● No developer tool caches found.")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                // Cache rows: monospaced, terminal-style.
                VStack(spacing: 0) {
                    ForEach(Array(devTools.enumerated()), id: \.element.id) { idx, info in
                        cacheRow(info, isOdd: idx % 2 == 1)
                        if idx < devTools.count - 1 {
                            Divider().opacity(0.3)
                        }
                    }
                }

                Divider()

                HStack {
                    Spacer()
                    Button {
                        actionTrigger = DevActionTrigger(
                            title: "Clean all developer caches?",
                            actions: devTools.compactMap { actionForTool($0) },
                            kind: .devTerminal, note: nil)
                    } label: {
                        Text("clean --all")
                            .font(.callout.monospaced().bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.vertical, 6)
                    .padding(.trailing, 12)
                }
            }
        }
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func cacheRow(_ info: DevToolInfo, isOdd: Bool) -> some View {
        HStack(spacing: 0) {
            // Icon
            Image(systemName: info.tool.icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 30, alignment: .center)
                .padding(.horizontal, 8)

            // Tool name + version
            HStack(spacing: 6) {
                Text(info.tool.displayName)
                    .font(.callout.monospaced())
                if let v = info.version {
                    Text(v)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 160, alignment: .leading)

            // Description
            Text(info.tool.cleanDescription)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)

            // Size / count
            if info.tool == .simctl, info.simctlUnavailableCount > 0 {
                Text("\(info.simctlUnavailableCount) unavailable")
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .frame(width: 120, alignment: .trailing)
                    .padding(.horizontal, 8)
            } else {
                Text(info.cacheBytes.formattedBytes)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(width: 120, alignment: .trailing)
                    .padding(.horizontal, 8)
            }

            // Clean button
            Button("clean") { cleanTool(info) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.caption2.monospaced())
                .frame(width: 60)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 4)
        .background(isOdd ? Color.black.opacity(0.02) : Color.clear)
    }

    // MARK: - Docker Volumes

    @ViewBuilder
    private var dockerVolumeSection: some View {
        if DockerScanner.availability() == .available {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "cylinder.split.1x2")
                        .font(.callout.monospaced())
                    Text("$ docker volume prune -f")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.black.opacity(0.06))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Removes unused Docker volumes — those not referenced by any container.")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button {
                            actionTrigger = DevActionTrigger(
                                title: "Prune unused Docker volumes?",
                                actions: [DockerVolumePruneAction()],
                                kind: .devTerminal, note: nil)
                        } label: {
                            Text("prune --volumes")
                                .font(.callout.monospaced().bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    }
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
            )
        }
    }

    // MARK: - System (Time Machine snapshots, merged from the former System tab)

    @ViewBuilder
    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.callout.monospaced())
                Text("$ tmutil listlocalsnapshots /")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if !snapshots.isEmpty {
                    Text("\(snapshots.count) snapshots")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.black.opacity(0.06))

            if isLoading && snapshots.isEmpty {
                HStack { Spacer(); ProgressView("Checking snapshots…"); Spacer() }
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if snapshots.isEmpty {
                Text("● No local snapshots.")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Local snapshots live on your startup volume and can tie up tens of GB. macOS creates and expires them automatically; deleting one frees space immediately and TM recreates snapshots on its next run.")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 8)

                    ForEach(snapshots) { snap in
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(snap.date)
                                .font(.callout.monospaced())
                            Spacer()
                            Button("delete") {
                                actionTrigger = DevActionTrigger(
                                    title: "Delete Time Machine snapshot?",
                                    actions: [DeleteSnapshotAction(snapshot: snap)],
                                    kind: .timeMachine,
                                    note: "Local snapshots are deleted immediately — this cannot be undone. macOS recreates them on their own backup schedule.")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(.red)
                            .font(.caption2.monospaced())
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        Divider().opacity(0.3).padding(.horizontal, 12)
                    }

                    HStack {
                        Spacer()
                        Button {
                            actionTrigger = DevActionTrigger(
                                title: "Delete all \(snapshots.count) Time Machine snapshots?",
                                actions: snapshots.map { DeleteSnapshotAction(snapshot: $0) },
                                kind: .timeMachine,
                                note: "Local snapshots are deleted immediately — this cannot be undone. macOS recreates them on their own backup schedule, so the space is reclaimed now and refilled as TM runs.")
                        } label: {
                            Text("delete --all")
                                .font(.callout.monospaced().bold())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                        .padding(.trailing, 12).padding(.bottom, 8)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
        )
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
        async let snapScan = Task.detached { TimeMachineScanner.listSnapshots() }.value
        let (p, t, s) = await (portScan, toolScan, snapScan)
        await MainActor.run {
            ports = p
            devTools = t
            snapshots = s
            isLoading = false
        }
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
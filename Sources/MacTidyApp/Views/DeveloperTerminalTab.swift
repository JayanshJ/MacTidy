import SwiftUI
import CoreKit

/// Developer Terminal tab on the dashboard. Styled like a real terminal —
/// dark background, monospaced fonts, colorized port labels — because the
/// user wants a developer-focused tool that feels like home, not a generic
/// settings panel.
///
/// Three sections:
/// 1. **Ports & Processes** — every TCP listening port, colorized by runtime
///    (Node=green, Python=yellow, Java=orange, Docker=blue, Database=purple,
///    Other=gray). Per-port Kill button (SIGTERM).
/// 2. **Package Manager Caches** — npm/yarn/pnpm/brew/cargo/simctl cache sizes
///    with one-click clean actions.
/// 3. **Docker Volumes** — prunes unused Docker volumes.
///
/// All destructive actions are `ShellAction`s routed through
/// `ShellActionConfirmationSheet` — irreversible, command shown verbatim.
struct DeveloperTerminalTab: View {
    @Environment(AppState.self) private var state
    @State private var ports: [PortEntry] = []
    @State private var devTools: [DevToolInfo] = []
    @State private var isLoading = false
    @State private var pending: [any ShellAction] = []
    @State private var showSheet = false
    @State private var sheetTitle = "Developer Terminal actions"
    @State private var infoEntry: PortEntry?
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    portsSection
                    cachesSection
                    dockerVolumeSection
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showSheet) {
            ShellActionConfirmationSheet(
                title: sheetTitle,
                actions: pending,
                kind: .devTerminal,
                note: "These commands run directly — they don't go through the Trash. Package caches rebuild on demand, but make sure you're not mid-build before cleaning.",
                onCompleted: { Task { await load() } }
            )
        }
        .sheet(isPresented: $showInfo) {
            if let entry = infoEntry {
                PortInfoSheet(entry: entry) { showInfo = false }
            }
        }
        .task { await load() }
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
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("What is this?")
                }
                Button("kill") {
                    pending = [KillProcessAction(pid: entry.pid, name: entry.processName, port: entry.port)]
                    sheetTitle = "Kill process?"
                    showSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
                .font(.caption2.monospaced())
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
                        pending = devTools.compactMap { actionForTool($0) }
                        sheetTitle = "Clean all developer caches?"
                        showSheet = true
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
                            pending = [DockerVolumePruneAction()]
                            sheetTitle = "Prune unused Docker volumes?"
                            showSheet = true
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

    // MARK: - Actions

    private func cleanTool(_ info: DevToolInfo) {
        guard let action = actionForTool(info) else { return }
        pending = [action]
        sheetTitle = "Clean \(info.tool.displayName)?"
        showSheet = true
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
        let (p, t) = await (portScan, toolScan)
        await MainActor.run {
            ports = p
            devTools = t
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
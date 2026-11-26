import SwiftUI
import AppKit
import CoreKit

struct InspectAppTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Unified inspector sheet for any `.app` bundle: architecture (Apple Silicon /
/// Universal / Rosetta 2), signing identity, running processes & ports, launch
/// agents, ~/Library data, and privacy usage declarations.
struct AppInspectorSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let appURL: URL

    @State private var report: AppInspector.Report?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        header(report)
                        summaryGrid(report)
                        if !report.runningProcesses.isEmpty || !report.listeningPorts.isEmpty {
                            runtimeSection(report)
                        }
                        if !report.launchItems.isEmpty {
                            launchSection(report)
                        }
                        if !report.dataPaths.isEmpty {
                            dataSection(report)
                        }
                        privacySection(report)
                    }
                    .padding(Theme.Spacing.xl)
                }
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView("Inspecting \(appURL.deletingPathExtension().lastPathComponent)…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                Button("Show in Finder") { showInFinder(appURL) }
                Button("Open App") {
                    NSWorkspace.shared.openApplication(
                        at: appURL,
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: 640, height: 600)
        .background(Theme.canvas)
        .task { await loadReport() }
    }

    private func header(_ r: AppInspector.Report) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(nsImage: FileIcon.image(for: r.appURL))
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(r.name).font(Theme.Font.title)
                    Badge(
                        text: r.architecture.rawValue,
                        tint: r.architecture.isIntelOnly ? Theme.Status.caution : Theme.accent
                    )
                }
                HStack(spacing: Theme.Spacing.sm) {
                    if let version = r.version {
                        Text("v\(version)")
                    }
                    if let bundleID = r.bundleID {
                        Text(bundleID)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)

                if let signing = r.signing {
                    Text(signing.label)
                        .font(Theme.Font.caption)
                        .foregroundStyle(signing.isAdHoc ? Theme.Status.caution : .secondary)
                }
            }
            Spacer()
        }
    }

    private func summaryGrid(_ r: AppInspector.Report) -> some View {
        HStack(spacing: Theme.Spacing.xl) {
            stat("App size", r.bundleSizeBytes.formattedBytes)
            stat("Library data", r.totalDataBytes.formattedBytes)
            stat("Memory", r.memoryBytes?.formattedBytes ?? (r.runningProcesses.isEmpty ? "Not running" : "Unavailable"))
            stat("CPU", r.runningProcesses.isEmpty ? "0%" : String(format: "%.1f%%", r.cpuPercent))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func runtimeSection(_ r: AppInspector.Report) -> some View {
        SurfaceSection("Processes & ports") {
            ForEach(Array(r.runningProcesses.prefix(6).enumerated()), id: \.element.id) { index, proc in
                if index > 0 { RowDivider() }
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proc.name).font(Theme.Font.bodyStrong)
                        Text("PID \(proc.pid)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(String(format: "%.1f%% CPU", proc.cpuPercent))
                        .font(Theme.Font.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(proc.physicalFootprintBytes?.formattedBytes ?? "Unavailable")
                        .font(Theme.Font.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .trailing)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm + 2)
            }
            if !r.listeningPorts.isEmpty {
                if !r.runningProcesses.isEmpty { RowDivider() }
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Listening ports").font(Theme.Font.bodyStrong)
                    Spacer()
                    Text(r.listeningPorts.map { ":\($0.port)" }.joined(separator: "  "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm + 2)
            }
        }
    }

    private func launchSection(_ r: AppInspector.Report) -> some View {
        SurfaceSection("Background launch items") {
            ForEach(Array(r.launchItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider() }
                HStack(spacing: Theme.Spacing.md) {
                    Circle()
                        .fill(item.isLoaded ? Theme.accent : Theme.track)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(item.label).font(Theme.Font.bodyStrong).lineLimit(1)
                            if item.isBroken {
                                Badge(text: "Missing binary", tint: Theme.Status.caution)
                            }
                        }
                        Text(item.domain.rawValue)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showInFinder(item.url) } label: {
                        Image(systemName: "arrow.up.forward.square").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm + 2)
            }
        }
    }

    private func dataSection(_ r: AppInspector.Report) -> some View {
        SurfaceSection("Library data") {
            ForEach(Array(r.dataPaths.prefix(8).enumerated()), id: \.element.id) { index, path in
                if index > 0 { RowDivider() }
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path.bucket.displayName).font(Theme.Font.bodyStrong)
                        Text(path.url.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(path.sizeBytes.formattedBytes)
                        .font(Theme.Font.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { showInFinder(path.url) } label: {
                        Image(systemName: "arrow.up.forward.square").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm + 2)
            }
        }
    }

    private func privacySection(_ r: AppInspector.Report) -> some View {
        SurfaceSection("Permissions & System Settings",
                       footer: "macOS manages privacy grants in System Settings. Click any pane below to review or revoke access.") {
            if r.privacyDeclarations.isEmpty {
                Text("No Info.plist privacy usage descriptions declared.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
            } else {
                ForEach(Array(r.privacyDeclarations.enumerated()), id: \.element.id) { index, decl in
                    if index > 0 { RowDivider() }
                    HStack(spacing: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(decl.title).font(Theme.Font.bodyStrong)
                            Text(decl.reason)
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Review…") { NSWorkspace.shared.open(decl.settingsURL) }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.sm + 2)
                }
            }
            RowDivider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(AppInspector.PrivacyPaneLink.standardPanes) { pane in
                        Button {
                            NSWorkspace.shared.open(pane.url)
                        } label: {
                            Label(pane.title, systemImage: pane.symbol)
                                .font(Theme.Font.caption)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.Font.bodyStrong.monospacedDigit())
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }

    private func loadReport() async {
        let url = appURL
        let processes = state.memory.processes
        let existingPorts = state.devPorts
        let footprints = state.appAttributions
        let built = await Task.detached(priority: .userInitiated) {
            let procs = processes.isEmpty ? ProcessScanner.scan() : processes
            let ports = existingPorts.isEmpty ? PortScanner.scan() : existingPorts
            let launch = LaunchItemsAuditor.audit()
            return AppInspector.inspect(
                appURL: url,
                processes: procs,
                ports: ports,
                launchItems: launch,
                footprints: footprints
            )
        }.value
        report = built
    }
}

import SwiftUI
import AppKit
import CoreKit

struct VitalsView: View {
    @Environment(AppState.self) private var state
    @State private var appSort = VitalsAppSort.cpu
    @State private var quitSheet: QuitTarget?
    @State private var inspectTarget: InspectAppTarget?
    @State private var appToQuit: RunningAppMemory?
    @State private var quitMessage: String?

    var body: some View {
        Page("System Vitals",
             subtitle: "Live CPU, memory, thermal pressure, and battery health.") {
            Button { Task { await refreshAll() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } content: {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                cpuCard
                batteryCard
            }
            MemoryCard(quitSheet: $quitSheet)
            activeAppsSection
        }
        .sheet(item: $quitSheet) { target in
            QuitConfirmationSheet(apps: target.names) { _ in
                Task { await refreshAll() }
            }
        }
        .sheet(item: $inspectTarget) { target in
            AppInspectorSheet(appURL: target.url)
        }
        .alert("Quit \(appToQuit?.name ?? "")?", isPresented: Binding(
            get: { appToQuit != nil },
            set: { if !$0 { appToQuit = nil } }
        )) {
            Button("Cancel", role: .cancel) { appToQuit = nil }
            Button("Quit", role: .destructive) {
                if let target = appToQuit { quitGracefully(target) }
                appToQuit = nil
            }
        } message: {
            Text("Requests a graceful quit so \(appToQuit?.name ?? "the app") can save open documents.")
        }
        .alert("Couldn't Quit App", isPresented: Binding(
            get: { quitMessage != nil },
            set: { if !$0 { quitMessage = nil } }
        )) {
            Button("OK", role: .cancel) { quitMessage = nil }
        } message: {
            Text(quitMessage ?? "")
        }
        .task {
            guard !SnapshotHarness.isActive else { return }
            while !Task.isCancelled {
                await refreshAll()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }

    // MARK: - CPU & Thermal

    @ViewBuilder
    private var cpuCard: some View {
        let snap = state.vitals.snapshot
        let thermal = snap?.thermal ?? .nominal
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("CPU & Thermal").font(Theme.Font.section)
                Spacer()
                Badge(text: thermal.displayName, tint: thermalColor(thermal))
            }
            if let cpu = snap?.cpu {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(cpu.usagePercent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(Theme.Font.figure)
                    if let chip = cpu.chipName {
                        Text(chip)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Meter(fraction: (cpu.usagePercent ?? 0) / 100, tint: cpuColor(cpu.usagePercent), height: 5)
                HStack(spacing: Theme.Spacing.xl) {
                    stat("Load (1m)", String(format: "%.2f", cpu.load1m))
                    stat("Cores", "\(cpu.coreCount)")
                    stat("Uptime", formattedDuration(cpu.uptimeSeconds))
                }
                Text(thermal.summary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Reading CPU vitals…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardStyle()
    }

    // MARK: - Battery & Power

    @ViewBuilder
    private var batteryCard: some View {
        let batt = state.vitals.snapshot?.battery
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Battery & Power").font(Theme.Font.section)
                Spacer()
                if let batt {
                    Badge(text: batteryStatusLabel(batt), tint: batteryStatusColor(batt))
                } else {
                    Badge(text: "AC Power", tint: .secondary)
                }
            }
            if let batt {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text("\(batt.chargePercent)%")
                        .font(Theme.Font.figure)
                    if let watts = batt.adapterWatts {
                        Text("\(watts) W adapter")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Meter(fraction: Double(batt.chargePercent) / 100, tint: batteryBarColor(batt), height: 5)
                HStack(spacing: Theme.Spacing.xl) {
                    stat("Health", batt.healthPercent.map { "\($0)%" } ?? "—")
                    stat("Cycles", batt.cycleCount.map(String.init) ?? "—")
                    stat(batt.isCharging ? "To full" : "Remaining",
                         batt.timeRemainingMinutes.map(formattedMinutes) ?? (batt.isPluggedIn ? "Plugged in" : "—"))
                }
                if let maxCap = batt.maxCapacityMAh, let designCap = batt.designCapacityMAh {
                    Text("Full charge capacity: \(maxCap.formatted()) / \(designCap.formatted()) mAh\(batt.designCycleCount.map { " · Rated \($0) cycles" } ?? "")")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Battery telemetry read from AppleSmartBattery.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No internal battery")
                    .font(Theme.Font.figure)
                Text("This Mac runs on AC power with no internal battery.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardStyle()
    }

    // MARK: - Active Apps

    private var activeAppsSection: some View {
        let ranked: [RunningAppMemory] = {
            let list = appSort == .cpu
                ? RunningAppMemory.topByCPU(state.memory.processes)
                : state.memory.apps
            return Array(list.prefix(8))
        }()

        return SurfaceSection("Running apps") {
            Picker("Sort", selection: $appSort) {
                ForEach(VitalsAppSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            if ranked.isEmpty {
                Text("No running app processes measured yet.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.lg)
            } else {
                ForEach(Array(ranked.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { RowDivider(inset: 52) }
                    appRow(app)
                }
            }
        }
    }

    private func appRow(_ app: RunningAppMemory) -> some View {
        let isSelf = app.path == Bundle.main.bundlePath
        return HStack(spacing: Theme.Spacing.md) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(Theme.Font.bodyStrong)
                    .lineLimit(1)
                if app.processes.count > 1 {
                    Text("\(app.processes.count) processes")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Spacing.lg)
            Text(String(format: "%.1f%% CPU", app.cpuPercent))
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(app.cpuPercent >= 50 ? Theme.Status.caution : .secondary)
                .frame(width: 84, alignment: .trailing)
            Text(app.footprintBytes?.formattedBytes ?? "Unavailable")
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .trailing)
            Button {
                inspectTarget = InspectAppTarget(url: URL(fileURLWithPath: app.path))
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Inspect app")
            Button {
                showInFinder(URL(fileURLWithPath: app.path))
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button("Quit") {
                appToQuit = app
            }
            .controlSize(.small)
            .disabled(!app.canQuitGracefully || isSelf)
            .help(isSelf ? "MacTidy itself" : (app.canQuitGracefully ? "Request graceful quit" : "Protected system app"))
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm + 2)
    }

    // MARK: - Helpers

    private func refreshAll() async {
        async let vitals: Void = state.vitals.refresh()
        async let mem: Void = state.memory.refresh()
        _ = await (vitals, mem)
    }

    private func quitGracefully(_ app: RunningAppMemory) {
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == app.path && $0.activationPolicy == .regular
        } ?? NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == app.path
        }
        guard let target = running,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            quitMessage = "\(app.name) is no longer running."
            return
        }
        if !target.terminate() {
            quitMessage = "\(app.name) declined a graceful quit. Check if it has an open save dialog."
        } else {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                await refreshAll()
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.Font.bodyStrong.monospacedDigit())
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }

    private func thermalColor(_ level: SystemVitals.ThermalLevel) -> Color {
        switch level {
        case .nominal: Theme.accent
        case .fair: .secondary
        case .serious: Theme.Status.caution
        case .critical: Theme.Status.blocked
        }
    }

    private func cpuColor(_ usage: Double?) -> Color {
        guard let usage else { return Theme.accent }
        if usage >= 85 { return Theme.Status.blocked }
        if usage >= 60 { return Theme.Status.caution }
        return Theme.accent
    }

    private func batteryStatusLabel(_ batt: SystemVitals.BatteryVitals) -> String {
        if batt.isCharging { return "Charging" }
        if batt.isFullyCharged && batt.isPluggedIn { return "Charged" }
        if batt.isPluggedIn { return "Plugged In" }
        return "On Battery"
    }

    private func batteryStatusColor(_ batt: SystemVitals.BatteryVitals) -> Color {
        if !batt.isPluggedIn && batt.chargePercent <= 20 { return Theme.Status.caution }
        return Theme.accent
    }

    private func batteryBarColor(_ batt: SystemVitals.BatteryVitals) -> Color {
        if !batt.isPluggedIn && batt.chargePercent <= 15 { return Theme.Status.blocked }
        if !batt.isPluggedIn && batt.chargePercent <= 25 { return Theme.Status.caution }
        return Theme.accent
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds) / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let mins = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private func formattedMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

private enum VitalsAppSort: String, CaseIterable {
    case cpu = "Top CPU"
    case memory = "Top Memory"
}

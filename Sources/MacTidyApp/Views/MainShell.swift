import SwiftUI
import CoreKit

// MARK: - Navigation model

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, insights
    case projects, devTools, docker
    case uninstaller, appStorage, loginItems
    case duplicates, diskMap, timeMachine
    case trash, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .insights: "Insights"
        case .projects: "Projects"
        case .devTools: "Dev Tools"
        case .docker: "Docker"
        case .uninstaller: "Uninstaller"
        case .appStorage: "App Storage"
        case .loginItems: "Login Items"
        case .duplicates: "Duplicates"
        case .diskMap: "Disk Map"
        case .timeMachine: "Snapshots"
        case .trash: "Recently Trashed"
        case .history: "Cleanup Log"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .cleanup: "sparkles.rectangle.stack"
        case .insights: "lightbulb"
        case .projects: "folder"
        case .devTools: "terminal"
        case .docker: "shippingbox"
        case .uninstaller: "xmark.app"
        case .appStorage: "square.stack.3d.up"
        case .loginItems: "power"
        case .duplicates: "doc.on.doc"
        case .diskMap: "square.grid.3x3.square"
        case .timeMachine: "clock.arrow.circlepath"
        case .trash: "arrow.uturn.backward.circle"
        case .history: "list.bullet.rectangle"
        }
    }

    enum Group: CaseIterable {
        case main, developer, apps, files, history
        var title: String? {
            switch self {
            case .main: nil
            case .developer: "Developer"
            case .apps: "Apps"
            case .files: "Files"
            case .history: "History"
            }
        }
        var items: [SidebarItem] {
            switch self {
            case .main: [.overview, .cleanup, .insights]
            case .developer: [.projects, .devTools, .docker]
            case .apps: [.uninstaller, .appStorage, .loginItems]
            case .files: [.duplicates, .diskMap, .timeMachine]
            case .history: [.trash, .history]
            }
        }
    }
}

// MARK: - Shell

/// The main window: a native sidebar and one page at a time.
struct MainShell: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Picking a page in the sidebar starts it fresh; deep links (Overview
        // rows) set section and category together and keep both.
        let selection = Binding<SidebarItem?>(
            get: { state.section },
            set: { if let item = $0 { state.section = item; state.drilledCategory = nil; state.selectedProjectID = nil } })
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SidebarItem.Group.allCases, id: \.self) { group in
                    Section {
                        ForEach(group.items) { item in
                            SidebarRow(item: item).tag(item)
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { DiskFooter() }
            .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if state.fdaSkipped && !state.fdaGranted { LimitedModeBanner() }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.canvas)
            .overlay(alignment: .bottom) {
                VStack(spacing: Theme.Spacing.sm) {
                    FirstReclaimCelebration()
                    UndoToast()
                }
                .padding(.bottom, Theme.Spacing.lg)
                .animation(Theme.ease, value: state.lastUndoableOutcome?.label)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) { Spacer() }
                ToolbarItemGroup(placement: .automatic) {
                    ScanToolbarButton()
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Settings")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.section {
        case .overview: OverviewView()
        case .cleanup: CleanupView()
        case .insights: InsightsTab()
        case .projects: ProjectsView()
        case .devTools: DeveloperTerminalTab()
        case .docker: DashboardDocker()
        case .uninstaller: DashboardUninstaller()
        case .appStorage: StorageByAppTab()
        case .loginItems: DashboardStartup()
        case .duplicates: DuplicatesView()
        case .diskMap: DirectoryExplorerView()
        case .timeMachine: SystemTab()
        case .trash: TrashView()
        case .history: CleanupHistoryView()
        }
    }
}

private struct SidebarRow: View {
    @Environment(AppState.self) private var state
    let item: SidebarItem

    var body: some View {
        HStack {
            Label(item.title, systemImage: item.symbol)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trailing: String? {
        switch item {
        case .cleanup:
            let bytes = state.totalReclaimable
            return bytes > 0 ? bytes.formattedBytes : nil
        case .trash:
            return state.recentTrashed.isEmpty ? nil : "\(state.recentTrashed.count)"
        default:
            return nil
        }
    }
}

/// Boot-volume capacity, pinned under the sidebar.
private struct DiskFooter: View {
    @Environment(AppState.self) private var state
    @State private var pressure = DiskPressure.current()

    var body: some View {
        if let pressure, pressure.isAvailable {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Macintosh HD").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(pressure.freeBytes.formattedBytes) free")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                CapacityBar(total: pressure.totalBytes, free: pressure.freeBytes,
                            cleanable: state.totalReclaimable, height: 5)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .onChange(of: state.lastScanDate) { _, _ in self.pressure = DiskPressure.current() }
            .onChange(of: state.recentTrashed.count) { _, _ in self.pressure = DiskPressure.current() }
        }
    }
}

/// Toolbar scan control: a button at rest, progress while scanning.
private struct ScanToolbarButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isScanningCategories || state.flowPhase == .scanning {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Scanning").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.sm)
        } else {
            Button {
                Task { await state.startFlow() }
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .help("Scan again")
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @Environment(AppState.self) private var state
    @State private var confirmPlan: DeletionPlan?
    @State private var pressure = DiskPressure.current()

    private var safeItems: [ScanItem] {
        state.categoryResults.flatMap(\.items).filter(\.isPreselectable)
    }

    var body: some View {
        if state.flowPhase == .scanning || (state.isScanningCategories && state.categoryResults.isEmpty) {
            ScanningOverview()
        } else {
            content
        }
    }

    private var content: some View {
        let safe = safeItems
        let safeBytes = safe.reduce(0) { $0 + $1.sizeBytes }
        let reviewBytes = state.totalReclaimable - safeBytes
        let ranked = state.categoryResults.filter { $0.totalBytes > 0 }
            .sorted { $0.totalBytes > $1.totalBytes }

        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                hero(safeBytes: safeBytes, safeCount: safe.count, reviewBytes: reviewBytes)
                if let pressure, pressure.isAvailable { capacity(pressure, safe: safeBytes, review: reviewBytes) }
                if state.trashBytes >= TrashNudgeCard.threshold { TrashNudgeCard() }
                growing
                if !ranked.isEmpty { breakdown(ranked) }
                footerStat
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .sheet(item: $confirmPlan) { plan in
            DeletionConfirmationSheet(title: "Clean everything that's safe?", plan: plan) { _ in
                Task { await state.rescanCategories() }
            }
        }
        .onChange(of: state.lastScanDate) { _, _ in pressure = DiskPressure.current() }
    }

    @ViewBuilder
    private func hero(safeBytes: Int64, safeCount: Int, reviewBytes: Int64) -> some View {
        if state.totalReclaimable == 0 {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Nothing worth cleaning")
                    .font(.system(size: 30, weight: .semibold))
                Text(scanAge.map { "Scanned \($0). Caches and build output will show up here as they grow." }
                     ?? "Run a scan to see what can be cleaned.")
                    .font(Theme.Font.body).foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .bottom, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(safeBytes.formattedBytes)
                        .font(Theme.Font.display)
                        .contentTransition(.numericText())
                    Text(heroCaption(count: safeCount, reviewBytes: reviewBytes))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.lg)
                VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                    Button {
                        confirmPlan = DeletionPlan(items: safeItems)
                    } label: {
                        Text("Clean Safe Items")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, Theme.Spacing.sm)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(safeBytes == 0)
                    Button("Review by category") { state.section = .cleanup }
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                }
            }
        }
    }

    private func heroCaption(count: Int, reviewBytes: Int64) -> String {
        var parts = ["safe to remove across \(count) item\(count == 1 ? "" : "s")"]
        if reviewBytes > 0 { parts.append("\(reviewBytes.formattedBytes) more worth reviewing") }
        if let scanAge { parts.append("scanned \(scanAge)") }
        return parts.joined(separator: "  ·  ")
    }

    private var scanAge: String? {
        guard let date = state.lastScanDate else { return nil }
        return date.formatted(.relative(presentation: .named))
    }

    private func capacity(_ p: DiskPressure, safe: Int64, review: Int64) -> some View {
        let usedOther = max(0, p.totalBytes - p.freeBytes - safe - review)
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            CapacityBar(total: p.totalBytes, free: p.freeBytes, cleanable: safe, review: review)
            HStack(spacing: Theme.Spacing.xl) {
                LegendItem(color: Theme.used, label: "In use", value: usedOther.formattedBytes)
                LegendItem(color: Theme.accent, label: "Safe to clean", value: safe.formattedBytes)
                if review > 0 {
                    LegendItem(color: Theme.accent.opacity(0.4), label: "Worth reviewing", value: review.formattedBytes)
                }
                LegendItem(color: Theme.track, label: "Free", value: p.freeBytes.formattedBytes)
                Spacer()
                Text("\(p.totalBytes.formattedBytes) disk")
                    .font(Theme.Font.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// Categories that grew since a scan at least a day older.
    @ViewBuilder
    private var growing: some View {
        let growth = ScanHistory.growers(in: state.scanHistory)
        if !growth.isEmpty {
            SurfaceSection("Growing", footer: "Compared with your scan from \(growth[0].since.formatted(.relative(presentation: .named))).") {
                ForEach(Array(growth.enumerated()), id: \.element.id) { index, g in
                    if index > 0 { RowDivider(inset: 48) }
                    Button {
                        state.section = .cleanup
                        state.drilledCategory = g.category
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: g.category.symbol)
                                .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                            Text(g.category.displayName).font(Theme.Font.bodyStrong)
                            Spacer()
                            Text("+\(g.delta.formattedBytes)")
                                .font(Theme.Font.bodyStrong.monospacedDigit())
                                .foregroundStyle(Theme.Status.caution)
                            Text("now \(g.current.formattedBytes)")
                                .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
    }

    private func breakdown(_ ranked: [CategoryResult]) -> some View {
        let top = Array(ranked.prefix(7))
        let maxBytes = top.first?.totalBytes ?? 1
        return SurfaceSection("Where the space is") {
            Button("All \(ranked.count) categories") { state.section = .cleanup }
                .buttonStyle(.link)
                .font(Theme.Font.caption)
        } content: {
            ForEach(Array(top.enumerated()), id: \.element.id) { index, result in
                if index > 0 { RowDivider(inset: 48) }
                Button {
                    state.section = .cleanup
                    state.drilledCategory = result.category
                } label: {
                    CategoryRow(result: result, maxBytes: maxBytes)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var footerStat: some View {
        let freed = state.totalReclaimedHistorically
        if freed > 0 {
            Text("MacTidy has freed \(freed.formattedBytes) across \(state.cleanupHistory.count) cleanup\(state.cleanupHistory.count == 1 ? "" : "s"). Everything went to the Trash first.")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// One category on a surface: icon, name, count, meter, size.
struct CategoryRow: View {
    let result: CategoryResult
    let maxBytes: Int64

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: result.category.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(result.category.displayName).font(Theme.Font.bodyStrong)
                    if !result.category.isPreselectable {
                        Badge(text: "Review", tint: Theme.Status.caution)
                    }
                }
                Text("\(result.items.count) item\(result.items.count == 1 ? "" : "s")")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.lg)
            Meter(fraction: Double(result.totalBytes) / Double(max(maxBytes, 1)),
                  tint: result.category.isPreselectable ? Theme.accent : Theme.used)
                .frame(width: 120)
            Text(result.totalBytes.formattedBytes)
                .font(Theme.Font.bodyStrong.monospacedDigit())
                .frame(width: 76, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }
}

// MARK: - Scanning

/// Live scan: a running total and each category as it finishes.
struct ScanningOverview: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let found = state.scanPartial.reduce(0) { $0 + $1.totalBytes }
        let recent = state.scanPartial.filter { $0.totalBytes > 0 }.suffix(8).reversed()
        let fraction = state.scanTotal > 0 ? Double(state.scanCompleted) / Double(state.scanTotal) : 0

        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(found.formattedBytes)
                    .font(Theme.Font.display)
                    .contentTransition(.numericText())
                    .animation(Theme.ease, value: found)
                Text("found so far  ·  \(state.scanProgress.isEmpty ? "Preparing" : state.scanProgress.replacingOccurrences(of: "…", with: ""))")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Meter(fraction: fraction, height: 6)
                    .animation(Theme.ease, value: fraction)
                Text("\(state.scanCompleted) of \(state.scanTotal) checks")
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if !recent.isEmpty {
                let maxBytes = recent.map(\.totalBytes).max() ?? 1
                SurfaceSection("Found") {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, result in
                        if index > 0 { RowDivider(inset: 48) }
                        CategoryRow(result: result, maxBytes: maxBytes)
                            .transition(.opacity)
                    }
                }
                .animation(Theme.ease, value: state.scanPartial.count)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Theme.Spacing.xxl)
        .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
    }
}

// MARK: - Toasts

/// Post-cleanup Undo toast: restores everything just trashed.
struct UndoToast: View {
    @Environment(AppState.self) private var state
    @State private var isRestoring = false
    @State private var restoreErrors: [String] = []

    var body: some View {
        if let outcome = state.lastUndoableOutcome {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: restoreErrors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(restoreErrors.isEmpty ? Theme.accent : Theme.Status.caution)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.label).font(Theme.Font.bodyStrong)
                    Text(restoreErrors.isEmpty
                         ? "Moved to the Trash. Undo puts it back."
                         : "Couldn't restore: \(restoreErrors.joined(separator: ", "))")
                        .font(Theme.Font.caption)
                        .foregroundStyle(restoreErrors.isEmpty ? Color.secondary : Theme.Status.caution)
                }
                Spacer(minLength: Theme.Spacing.lg)
                Button {
                    restoreAll(outcome.records)
                } label: {
                    if isRestoring { ProgressView().controlSize(.small) } else { Text("Undo") }
                }
                .disabled(isRestoring)
                Button { state.clearUndoToast() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(12))
                state.clearUndoToast()
            }
        }
    }

    private func restoreAll(_ records: [TrashRecord]) {
        isRestoring = true
        restoreErrors = []
        Task {
            var errors: [String] = []
            for record in records {
                do { _ = try state.restore(record) } catch { errors.append(record.original.lastPathComponent) }
            }
            isRestoring = false
            restoreErrors = errors
            if errors.isEmpty { state.clearUndoToast() }
        }
    }
}

// MARK: - Category symbols

extension CoreKit.Category {
    var symbol: String {
        switch self {
        case .xcodeDerivedData: "hammer"
        case .xcodeDeviceSupport: "iphone"
        case .simulatorCaches: "ipad.and.iphone"
        case .simulatorRuntimes: "square.stack.3d.down.right"
        case .simulatorDevices: "iphone.homebutton"
        case .xcodeArchives: "archivebox"
        case .userCaches: "tray.2"
        case .homebrewCache: "mug"
        case .nodeModules: "shippingbox"
        case .rustTargets: "gearshape.2"
        case .podDirs: "cube"
        case .swiftBuildDirs: "swift"
        case .gradleBuildDirs: "square.stack.3d.up"
        case .pythonCaches: "chevron.left.forwardslash.chevron.right"
        case .jsBuildDirs: "curlybraces"
        case .containerCaches: "square.on.square"
        case .mailDownloads: "envelope"
        case .mavenTarget: "cup.and.saucer"
        case .phpVendor: "chevron.left.slash.chevron.right"
        case .flutterDartTool: "bird"
        case .unityLibrary: "cube.transparent"
        case .androidSystemImages: "candybarphone"
        case .staleScreenshots: "camera.viewfinder"
        case .oldInstallers: "opticaldiscdrive"
        case .iosBackups: "externaldrive.badge.timemachine"
        case .devCaches: "terminal"
        case .aiAgents: "cpu"
        case .appSupport: "folder"
        case .bigFiles: "doc"
        case .systemLogs: "list.bullet.rectangle"
        case .crashReports: "exclamationmark.triangle"
        case .savedAppState: "macwindow"
        case .httpStorages: "globe"
        case .groupContainers: "folder.badge.person.crop"
        }
    }
}

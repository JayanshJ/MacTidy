import SwiftUI
import CoreKit

/// The redesigned app shell: a single-window guided flow, no sidebar. The
/// top bar carries back navigation, step pips, and the escape hatches
/// (Recently Trashed, Browse disk, Settings). The body switches on the
/// current flow phase.
struct FlowView: View {
    @Environment(AppState.self) private var state
    @State private var showSettings = false
    @State private var showTrash = false
    @State private var showDisk = false

    var body: some View {
        VStack(spacing: 0) {
            FlowToolbar(
                showSettings: $showSettings,
                showTrash: $showTrash,
                showDisk: $showDisk
            )
            Divider()
            content
        }
        .frame(minWidth: 880, minHeight: 620)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showTrash) { TrashSheetView() }
        .sheet(isPresented: $showDisk) { DiskSheetView() }
        .overlay(alignment: .bottom) {
            VStack(spacing: Theme.Spacing.sm) {
                FirstReclaimCelebration()
                UndoToast()
            }
            .padding(.bottom, Theme.Spacing.md)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.flowPhase {
        case .welcome: WelcomeView()
        case .scanning: ScanningView()
        case .dashboard: DashboardView()
        case .allClean: AllCleanView()
        }
    }
}

/// Sheet wrapper for Recently Trashed.
struct TrashSheetView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recently Trashed").font(.headline)
                Spacer()
                if !state.recentTrashed.isEmpty {
                    Button("Clear List") {
                        state.recentTrashed.forEach { state.dismissTrashed($0) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Remove all entries from this list (items stay in the Trash).")
                }
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
            Divider()
            TrashView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 560)
    }
}

/// Sheet wrapper for the disk explorer / treemap.
struct DiskSheetView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Browse Disk").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
            Divider()
            DiskView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 560, idealHeight: 640)
    }
}

/// The post-cleanup Undo toast. Appears whenever AppState has a fresh
/// outcome, offering to restore everything just trashed. Auto-dismisses after
/// a while so it doesn't camp on screen forever.
struct UndoToast: View {
    @Environment(AppState.self) private var state
    @State private var isRestoring = false

    var body: some View {
        if let outcome = state.lastUndoableOutcome {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Status.good)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.label).font(.callout.bold())
                    Text("Undo moves it back from the Trash.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    restoreAll(outcome.records)
                } label: {
                    if isRestoring { ProgressView().controlSize(.small) }
                    else { Text("Undo") }
                }
                .controlSize(.small)
                .disabled(isRestoring)
                Button {
                    state.clearUndoToast()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(12))
                state.clearUndoToast()
            }
        }
    }

    private func restoreAll(_ records: [TrashRecord]) {
        isRestoring = true
        Task {
            for record in records { _ = try? state.restore(record) }
            await MainActor.run {
                isRestoring = false
                state.clearUndoToast()
            }
        }
    }
}
struct FlowToolbar: View {
    @Environment(AppState.self) private var state
    @Binding var showSettings: Bool
    @Binding var showTrash: Bool
    @Binding var showDisk: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if state.flowPhase != .welcome {
                Button {
                    withAnimation(.snappy) { state.resetFlow() }
                } label: {
                    Label("Home", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(state.flowPhase == .scanning)
                .help("Back to welcome")
            }
            Spacer()
            Button { showDisk = true } label: {
                Label("Browse disk", systemImage: "internaldrive")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .imageScale(.medium)
            .help("Explore your disk manually")
            Button { showTrash = true } label: {
                Label("Recently trashed", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .imageScale(.medium)
            .badge(state.recentTrashed.count)
            .help("View and restore trashed items")
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .imageScale(.medium)
            .help("App settings")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }
}
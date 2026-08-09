import SwiftUI
import CoreKit

enum Feature: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case disk = "Disk"
    case uninstaller = "Uninstaller"
    case startup = "Startup Items"
    case duplicates = "Duplicates"
    case trashed = "Recently Trashed"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: "gauge.medium"
        case .disk: "internaldrive"
        case .uninstaller: "trash.slash"
        case .startup: "power"
        case .duplicates: "doc.on.doc"
        case .trashed: "trash"
        }
    }
}

struct MainSplitView: View {
    @Environment(AppState.self) private var state
    @State private var selection: Feature = .overview

    var body: some View {
        NavigationSplitView {
            List(Feature.allCases, selection: $selection) { feature in
                Label(feature.rawValue, systemImage: feature.systemImage)
                    .tag(feature)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection {
            case .overview: OverviewView()
            case .disk: DiskView()
            case .uninstaller: UninstallerView()
            case .startup: StartupItemsView()
            case .duplicates: DuplicatesView()
            case .trashed: TrashView()
            }
        }
        .overlay(alignment: .bottom) {
            UndoToast()
                .padding(.bottom, 16)
        }
    }
}

/// The post-cleanup Undo toast. Appears whenever AppState has a fresh
/// non-dry-run outcome, offering to restore everything just trashed. Auto-
/// dismisses after a while so it doesn't camp on screen forever.
struct UndoToast: View {
    @Environment(AppState.self) private var state
    @State private var isRestoring = false

    var body: some View {
        if let outcome = state.lastUndoableOutcome {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.label).font(.callout.bold())
                    Text("Undo moves it back from the Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    restoreAll(outcome.records)
                } label: {
                    if isRestoring {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Undo")
                    }
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
            .padding(12)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                // Auto-dismiss after 12s if the user ignores it.
                try? await Task.sleep(for: .seconds(12))
                state.clearUndoToast()
            }
        }
    }

    private func restoreAll(_ records: [TrashRecord]) {
        isRestoring = true
        Task {
            for record in records {
                _ = try? state.restore(record)
            }
            await MainActor.run {
                isRestoring = false
                state.clearUndoToast()
            }
        }
    }
}
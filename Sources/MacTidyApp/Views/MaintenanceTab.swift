import SwiftUI
import CoreKit

struct MaintenanceTab: View {
    @Environment(AppState.self) private var state
    @State private var tweakStates: [SystemTweakState] = []
    @State private var isLoading = false
    @State private var isApplyingTweak = false
    @State private var actionTrigger: MaintenanceTrigger?
    @State private var errorMessage: String?

    private var customizedCount: Int { tweakStates.filter(\.isCustomized).count }

    var body: some View {
        Page("Maintenance",
             subtitle: "Curated macOS maintenance tasks and reversible system tweaks. Every command is shown verbatim.") {
            if customizedCount > 0 {
                Button("Reset All Tweaks (\(customizedCount))") {
                    Task { await resetAllTweaks() }
                }
                .disabled(isApplyingTweak)
            }
            Button { Task { await loadTweaks() } } label: {
                if isLoading || isApplyingTweak {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isLoading || isApplyingTweak)
        } content: {
            maintenanceSection
            ForEach(SystemTweak.Category.allCases, id: \.self) { category in
                tweakSection(for: category)
            }
        }
        .sheet(item: $actionTrigger) { trigger in
            ShellActionConfirmationSheet(
                title: trigger.title,
                actions: trigger.actions,
                kind: .systemMaintenance,
                note: trigger.note
            )
        }
        .alert("Couldn't update macOS setting", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            if SnapshotHarness.isActive {
                tweakStates = SystemTweaks.catalog.map { SystemTweakState(tweak: $0, rawValue: nil) }
            } else if tweakStates.isEmpty {
                await loadTweaks()
            }
        }
    }

    // MARK: - Maintenance Actions

    private var maintenanceSection: some View {
        let items: [(title: String, subtitle: String, action: any ShellAction, note: String?)] = [
            (
                "Flush DNS cache",
                "Clears cached DNS lookups when domains or local dev hosts resolve to stale IPs.",
                FlushDNSCacheAction(),
                "Asks for your administrator password to restart mDNSResponder."
            ),
            (
                "Reset Quick Look cache",
                "Fixes stuck, blank, or stale Finder Spacebar previews without touching your files.",
                ResetQuickLookCacheAction(),
                nil
            ),
            (
                "Reset user font caches",
                "Clears corrupted font caches if apps show garbled text or missing font weights.",
                ClearFontCacheAction(),
                nil
            ),
            (
                "Thin Time Machine local snapshots",
                "Asks macOS to purge up to 10 GB of reclaimable local APFS snapshots safely.",
                ThinTimeMachineSnapshotsAction(),
                nil
            ),
            (
                "Rebuild Spotlight index",
                "Erases and rebuilds the Spotlight metadata index on your startup volume.",
                RebuildSpotlightIndexAction(),
                "Reindexing runs in the background and may temporarily use CPU. Asks for your administrator password."
            ),
            (
                "Restart Finder",
                "Relaunches Finder if windows freeze, icons glitch, or mounted drives stop updating.",
                RestartFinderAction(),
                nil
            ),
            (
                "Restart Dock",
                "Relaunches the Dock and resets Mission Control / Spaces responsiveness.",
                RestartDockAction(),
                nil
            ),
        ]

        return SurfaceSection("Quick maintenance",
                              footer: "Each task runs only after you confirm the command preview.") {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { RowDivider() }
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(Theme.Font.bodyStrong)
                        Text(item.subtitle)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                        Text(item.action.commandSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: Theme.Spacing.lg)
                    Button("Run…") {
                        actionTrigger = MaintenanceTrigger(
                            title: "\(item.title)?",
                            actions: [item.action],
                            note: item.note
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }

    // MARK: - Reversible Tweaks

    @ViewBuilder
    private func tweakSection(for category: SystemTweak.Category) -> some View {
        let entries = tweakStates.filter { $0.tweak.category == category }
        if !entries.isEmpty {
            SurfaceSection("\(category.rawValue) tweaks") {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { RowDivider() }
                    tweakRow(entry)
                }
            }
        }
    }

    private func tweakRow(_ entry: SystemTweakState) -> some View {
        let tweak = entry.tweak
        return HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(tweak.title).font(Theme.Font.bodyStrong)
                    if entry.isCustomized {
                        Badge(text: "Modified", tint: Theme.accent)
                    }
                }
                Text(tweak.subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                Text(commandPreview(for: entry))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Spacing.lg)
            if entry.isCustomized {
                Button("Reset") {
                    Task { await resetTweak(tweak) }
                }
                .controlSize(.small)
                .disabled(isApplyingTweak)
                .help(tweak.resetCommandPreview)
            }
            tweakControl(entry)
                .disabled(isApplyingTweak)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    @ViewBuilder
    private func tweakControl(_ entry: SystemTweakState) -> some View {
        switch entry.tweak.kind {
        case .bool:
            Toggle("", isOn: Binding(
                get: { entry.boolValue },
                set: { next in Task { await applyBool(next, for: entry.tweak) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        case .choice(let options, _):
            Picker("", selection: Binding(
                get: { entry.selectedChoiceValue },
                set: { nextValue in
                    if let option = options.first(where: { $0.value == nextValue }) {
                        Task { await applyChoice(option, for: entry.tweak) }
                    }
                }
            )) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 150)
        }
    }

    private func commandPreview(for entry: SystemTweakState) -> String {
        switch entry.tweak.kind {
        case .bool:
            return entry.tweak.writeCommandPreview(boolValue: entry.boolValue)
        case .choice(let options, _):
            if let current = options.first(where: { $0.value == entry.selectedChoiceValue }) {
                return entry.tweak.writeCommandPreview(option: current)
            }
            return entry.tweak.resetCommandPreview
        }
    }

    // MARK: - Actions

    private func loadTweaks() async {
        isLoading = true
        let read = await Task.detached(priority: .userInitiated) {
            SystemTweaks.readAll()
        }.value
        tweakStates = read
        isLoading = false
    }

    private func applyBool(_ value: Bool, for tweak: SystemTweak) async {
        isApplyingTweak = true
        let ok = await Task.detached(priority: .userInitiated) {
            SystemTweaks.setBool(value, for: tweak)
        }.value
        isApplyingTweak = false
        if !ok { errorMessage = "Failed to update \(tweak.domain) \(tweak.key)." }
        await loadTweaks()
    }

    private func applyChoice(_ option: SystemTweak.ChoiceOption, for tweak: SystemTweak) async {
        isApplyingTweak = true
        let ok = await Task.detached(priority: .userInitiated) {
            SystemTweaks.setChoice(option, for: tweak)
        }.value
        isApplyingTweak = false
        if !ok { errorMessage = "Failed to update \(tweak.domain) \(tweak.key)." }
        await loadTweaks()
    }

    private func resetTweak(_ tweak: SystemTweak) async {
        isApplyingTweak = true
        let ok = await Task.detached(priority: .userInitiated) {
            SystemTweaks.reset(tweak)
        }.value
        isApplyingTweak = false
        if !ok { errorMessage = "Failed to reset \(tweak.domain) \(tweak.key)." }
        await loadTweaks()
    }

    private func resetAllTweaks() async {
        isApplyingTweak = true
        let customized = tweakStates.filter(\.isCustomized).map(\.tweak)
        let ok = await Task.detached(priority: .userInitiated) {
            customized.allSatisfy { SystemTweaks.reset($0) }
        }.value
        isApplyingTweak = false
        if !ok { errorMessage = "Some tweaks could not be reset to macOS defaults." }
        await loadTweaks()
    }
}

private struct MaintenanceTrigger: Identifiable {
    let id = UUID()
    let title: String
    let actions: [any ShellAction]
    let note: String?
}

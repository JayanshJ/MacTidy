import SwiftUI
import CoreKit

/// Proactive "AI Insights" panel: the AI (or the deterministic fallback)
/// reasons over disk + memory + processes and surfaces narrative insights
/// with a proposed action. Each action routes through the existing
/// confirmation flow — trash via DeletionConfirmationSheet, quit-apps via a
/// dedicated sheet. The model never executes.
struct InsightsTab: View {
    @Environment(AppState.self) private var state
    @State private var insights: [Insight] = []
    @State private var isLoading = false
    @State private var sheetPlan: DeletionPlan?
    @State private var sheetReasoning: String?
    @State private var quitSheet: QuitTarget?
    @State private var usingAI = false
    @State private var aiIntent = ""
    @State private var isPlanning = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Trash suggested items?", plan: plan, reasoning: sheetReasoning) { _ in
                Task { await refresh() }
            }
        }
        .sheet(item: $quitSheet) { target in
            QuitConfirmationSheet(apps: target.names) { didQuit in
                if didQuit { Task { await refresh() } }
            }
        }
        .task { if insights.isEmpty { await refresh() } }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Insights").font(.title3.bold())
                    Text(usingAI ? "Reasoned by your configured AI model." : "Generated locally — add an AI provider in Settings for richer reasoning.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await refresh() } } label: {
                    if isLoading {
                        HStack { ProgressView().controlSize(.small); Text("Thinking…") }
                    } else {
                        Label("Refresh", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoading)
            }
            if state.aiConfig.provider != .none {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent)
                    TextField("Ask AI to clean… e.g. “free up 15 GB”, “clean Xcode stuff”", text: $aiIntent)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await runAIPlan() } }
                        .disabled(isPlanning)
                    if isPlanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await runAIPlan() }
                        } label: {
                            Label("Plan", systemImage: "arrow.up.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(aiIntent.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if insights.isEmpty && !isLoading {
            ContentUnavailableView(
                "Nothing to suggest",
                systemImage: "checkmark.seal",
                description: Text("No reclaimable disk, no idle memory hogs, and the OS isn't under pressure. You're tidy.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading && insights.isEmpty {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Reasoning over your disk, memory, and processes…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    MemoryCard(quitSheet: $quitSheet)
                    ForEach(insights) { insight in
                        insightCard(insight)
                    }
                }
                .padding(Theme.Spacing.xl)
            }
        }
    }

    private func insightCard(_ insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: insight.kind.icon).foregroundStyle(Theme.accent)
                Text(insight.kind.rawValue).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if insight.reclaimableBytes > 0 {
                    Text("~\(insight.reclaimableBytes.formattedBytes) reclaimable")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                }
            }
            Text(insight.reasoning).font(.callout)
            actionButton(for: insight)
        }
        .padding(Theme.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    @ViewBuilder
    private func actionButton(for insight: Insight) -> some View {
        switch insight.action {
        case .trash(let items):
            Button {
                sheetPlan = DeletionPlan(items: items)
            } label: {
                Label("Trash these · \(insight.reclaimableBytes.formattedBytes)", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .quitApps(let names):
            Button {
                quitSheet = QuitTarget(names: names)
            } label: {
                Label("Quit \(names.joined(separator: ", "))", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .observe:
            Text("No action — just so you know.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func refresh() async {
        isLoading = true
        usingAI = state.aiConfig.provider != .none && state.advisor != nil
        let result = await state.generateInsights()
        insights = result
        isLoading = false
    }

    /// Natural-language cleanup: ask the configured advisor for a plan matching
    /// the typed intent, then open the *existing* confirmation sheet with the
    /// advisor's reasoning shown above the plan. No new popup surface — it's
    /// the same sheet a manual "Trash Selected" uses. Falls back to the
    /// deterministic ranked plan when the call fails or AI is off.
    private func runAIPlan() async {
        let intent = aiIntent.trimmingCharacters(in: .whitespaces)
        guard !intent.isEmpty else { return }
        isPlanning = true
        defer { isPlanning = false }
        let result = await state.aiPlan(for: intent)
        guard !result.plan.isEmpty else { return }
        sheetReasoning = result.reasoning
        sheetPlan = result.plan
    }
}

/// Wraps an app-name list so it can drive a `.sheet(item:)`.
struct QuitTarget: Identifiable {
    let names: [String]
    var id: String { names.joined(separator: "|") }
}

/// Confirmation sheet for quitting apps. Shows which apps and the RAM that
/// would free, then runs `osascript -e 'tell app "Foo" to quit'` per app —
/// graceful quit, not a kill -9, so apps can save state.
struct QuitConfirmationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let apps: [String]
    let onCompleted: (Bool) -> Void
    @State private var results: [(String, Bool)] = []
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quit these apps?").font(.title2.bold())
            Text("A graceful quit (not force-kill), so each app can save its state. You can reopen them anytime.")
                .foregroundStyle(.secondary)
            List {
                ForEach(apps, id: \.self) { name in
                    HStack {
                        Image(systemName: appIcon(for: name))
                        Text(name)
                        Spacer()
                        if let r = results.first(where: { $0.0 == name }) {
                            Image(systemName: r.1 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.1 ? Theme.Status.good : .red)
                        }
                    }
                }
            }
            .listStyle(.bordered)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(done ? "Done" : "Quit") { quit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(done)
            }
        }
        .padding(20)
        .frame(width: 460, height: 320)
    }

    private func appIcon(for name: String) -> String { "app.dashed" }

    private func quit() {
        // Graceful quit via AppleScript — apps get a chance to save state,
        // unlike kill -9. Never used on denied/system processes (the resolver
        // already filtered those out before the insight reached here).
        for name in apps {
            let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "tell application \"\(escaped)\" to quit"
            let out = Shell.run("/usr/bin/osascript", ["-e", script])
            results.append((name, out?.succeeded ?? false))
        }
        done = true
        onCompleted(true)
    }
}
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
        Page("Insights",
             subtitle: usingAI ? "Suggestions reasoned by your AI model. Nothing runs without your confirmation."
                               : "Suggestions worked out on this Mac. Add an AI provider in Settings for richer reasoning.") {
            Button { Task { await refresh() } } label: {
                if isLoading { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .disabled(isLoading)
        } content: {
            if state.aiConfig.provider != .none { askBar }
            MemoryCard(quitSheet: $quitSheet)
            if isLoading && insights.isEmpty {
                ProgressView("Looking at disk, memory and processes").frame(maxWidth: .infinity).padding(Theme.Spacing.xl)
            } else if insights.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "Nothing to suggest",
                               message: "No reclaimable disk, no idle memory hogs, and macOS isn't under pressure.")
            } else {
                SurfaceSection("Suggestions") {
                    ForEach(Array(insights.enumerated()), id: \.element.id) { i, insight in
                        if i > 0 { RowDivider(inset: 48) }
                        insightRow(insight)
                    }
                }
            }
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

    /// Natural-language cleanup request.
    private var askBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent)
            TextField("Ask for a cleanup, like \u{201C}free up 15 GB\u{201D} or \u{201C}clear Xcode build data\u{201D}", text: $aiIntent)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit { Task { await runAIPlan() } }
                .disabled(isPlanning)
            if isPlanning {
                ProgressView().controlSize(.small)
            } else {
                Button("Plan") { Task { await runAIPlan() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(aiIntent.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .cardStyle(padded: false)
    }

    private func insightRow(_ insight: Insight) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: insight.kind.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(insight.reasoning)
                    .font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                actionButton(for: insight)
            }
            Spacer(minLength: Theme.Spacing.lg)
            if insight.reclaimableBytes > 0 {
                Text(insight.reclaimableBytes.formattedBytes)
                    .font(Theme.Font.bodyStrong.monospacedDigit())
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    @ViewBuilder
    private func actionButton(for insight: Insight) -> some View {
        switch insight.action {
        case .trash(let items):
            Button("Review and Clean…") { sheetPlan = DeletionPlan(items: items) }
                .controlSize(.small)
        case .quitApps(let names):
            Button("Quit \(names.joined(separator: ", "))…") { quitSheet = QuitTarget(names: names) }
                .controlSize(.small)
        case .observe:
            EmptyView()
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
            Text("Quit these apps?").font(.system(size: 17, weight: .semibold))
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
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(done)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460, height: 320)
        .background(Theme.canvas)
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
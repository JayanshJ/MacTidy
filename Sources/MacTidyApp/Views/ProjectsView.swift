import SwiftUI
import CoreKit

/// Repos under your developer folders, coldest-and-heaviest first.
struct ProjectsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let project = state.projects.first(where: { $0.id == state.selectedProjectID }) {
                ProjectDetail(project: project) { withAnimation(Theme.ease) { state.selectedProjectID = nil } }
            } else {
                list
            }
        }
        .task(id: state.lastScanDate) {
            if !state.categoryResults.isEmpty, state.projectsBuiltFrom != state.lastScanDate || state.projects.isEmpty {
                await state.refreshProjects()
            }
        }
    }

    private var list: some View {
        let projects = state.projects
        let withOutput = projects.filter { $0.artifactBytes > 0 || !$0.staleWorktrees.isEmpty }
        let quiet = projects.filter { $0.artifactBytes == 0 && $0.staleWorktrees.isEmpty }
        let total = projects.reduce(0) { $0 + $1.artifactBytes }
        let coldCount = projects.filter { $0.coldDays() >= 90 && $0.artifactBytes > 0 }.count
        let largest = withOutput.map(\.artifactBytes).max() ?? 1

        return Page("Projects",
                    subtitle: projects.isEmpty ? "Git repositories in your developer folders."
                        : "\(total.formattedBytes) of build output across \(projects.count) repos. \(coldCount) of them haven't been touched in three months.") {
            Button { Task { await state.refreshProjects() } } label: {
                if state.isScanningProjects { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .disabled(state.isScanningProjects || state.categoryResults.isEmpty)
        } content: {
            if state.categoryResults.isEmpty {
                EmptyStateView(symbol: "folder.badge.gearshape", title: "Scan first",
                               message: "Projects are built from a scan of your developer folders.")
            } else if projects.isEmpty {
                if state.isScanningProjects {
                    ProgressView("Reading your repositories").frame(maxWidth: .infinity).padding(Theme.Spacing.xxl)
                } else {
                    EmptyStateView(symbol: "folder.badge.gearshape", title: "No repositories found",
                                   message: "Add the folders where you keep code in Settings › Folders.")
                }
            } else {
                if !withOutput.isEmpty {
                    SurfaceSection("Worth cleaning", footer: "Ranked by how long a project has been idle times how much build output it holds.") {
                        rows(withOutput, largest: largest)
                    }
                }
                if !quiet.isEmpty {
                    SurfaceSection("Nothing to clean") {
                        rows(quiet, largest: largest)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ projects: [DevProject], largest: Int64) -> some View {
        ForEach(Array(projects.enumerated()), id: \.element.id) { i, project in
            if i > 0 { RowDivider(inset: 58) }
            Button { withAnimation(Theme.ease) { state.selectedProjectID = project.id } } label: {
                ProjectRow(project: project, largest: largest)
            }
            .buttonStyle(RowButtonStyle())
        }
    }
}

// MARK: - Row

private struct ProjectRow: View {
    let project: DevProject
    let largest: Int64

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: project.url.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(project.name).font(Theme.Font.bodyStrong).lineLimit(1)
                    ActivityBadge(days: project.coldDays())
                }
                Text(facts)
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.lg)
            if project.artifactBytes > 0 {
                Meter(fraction: Double(project.artifactBytes) / Double(max(largest, 1)),
                      tint: project.coldDays() >= 90 ? Theme.accent : Theme.used)
                    .frame(width: 110)
                Text(project.artifactBytes.formattedBytes)
                    .font(Theme.Font.bodyStrong.monospacedDigit())
                    .frame(width: 76, alignment: .trailing)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var facts: String {
        var parts: [String] = []
        if let branch = project.branch { parts.append(branch) }
        if let last = project.lastCommit {
            parts.append("last commit \(last.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("no commits")
        }
        if project.isDirty { parts.append("uncommitted changes") }
        if !project.staleWorktrees.isEmpty {
            parts.append("\(project.staleWorktrees.count) stale worktree\(project.staleWorktrees.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// Active / Idle / Cold, from days since last activity.
private struct ActivityBadge: View {
    let days: Int

    var body: some View {
        if days < 14 {
            Badge(text: "Active", tint: .secondary)
        } else if days < 90 {
            Badge(text: "Idle \(days / 7)w", tint: .secondary)
        } else {
            Badge(text: "Cold \(max(3, days / 30))mo", tint: Theme.accent)
        }
    }
}

// MARK: - Detail

private struct ProjectDetail: View {
    @Environment(AppState.self) private var state
    let project: DevProject
    let onBack: () -> Void

    @State private var selection = Set<UUID>()
    @State private var cleanPlan: DeletionPlan?
    @State private var pruneAction: PruneTrigger?
    @State private var showArchive = false

    var body: some View {
        let selected = project.artifacts.filter { selection.contains($0.id) }
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    Button(action: onBack) { Label("Projects", systemImage: "chevron.left").font(Theme.Font.body) }
                        .buttonStyle(.link)
                    header
                    facts
                    if !project.artifacts.isEmpty { buildOutput }
                    if project.worktrees.count > 1 || !project.staleWorktrees.isEmpty { worktrees }
                    archiveCard
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, Theme.Spacing.xl)
                .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if !project.artifacts.isEmpty {
                SelectionFooter(selectedCount: selected.count,
                                selectedBytes: selected.reduce(0) { $0 + $1.sizeBytes },
                                buttonTitle: "Move Build Output to Trash…", disabled: false) {
                    cleanPlan = DeletionPlan(items: selected)
                }
            }
        }
        .background(Theme.canvas)
        .onAppear { selection = Set(project.artifacts.map(\.id)) }
        .sheet(item: $cleanPlan) { plan in
            DeletionConfirmationSheet(title: "Clean build output in \(project.name)?", plan: plan) { _ in
                Task { await state.refreshProjects() }
            }
        }
        .sheet(item: $pruneAction) { trigger in
            ShellActionConfirmationSheet(
                title: "Prune stale worktrees?",
                actions: [GitWorktreePruneAction(repo: project.url, staleCount: trigger.count)],
                kind: .devTerminal,
                note: "Removes git's records of worktrees whose folders no longer exist. No files are touched.",
                onCompleted: { Task { await state.refreshProjects() } })
        }
        .sheet(isPresented: $showArchive) {
            ArchiveSheet(project: project) { archived in
                if archived { onBack() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: project.url.path))
                .resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(project.name).font(Theme.Font.title)
                    ActivityBadge(days: project.coldDays())
                }
                Text(project.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { showInFinder(project.url) } label: { Label("Finder", systemImage: "folder") }
            Button { openInTerminal() } label: { Label("Terminal", systemImage: "terminal") }
        }
    }

    private var facts: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xxl) {
            fact("Build output", project.artifactBytes.formattedBytes)
            fact("Git history", project.gitBytes.formattedBytes)
            fact("Last commit", project.lastCommit.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "None")
            fact("Status", status)
        }
    }

    private var status: String {
        if project.isDirty { return "Uncommitted changes" }
        if let n = project.unpushedCommits, n > 0 { return "\(n) unpushed" }
        if project.unpushedCommits == nil { return "No upstream" }
        return "Clean"
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.Font.figure)
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }

    private var buildOutput: some View {
        SurfaceSection("Build output", footer: "Rebuilt by the project's own tools (npm install, cargo build, …). Goes to the Trash.") {
            ForEach(Array(project.artifacts.enumerated()), id: \.element.id) { i, item in
                if i > 0 { RowDivider(inset: 70) }
                ScanItemRow(item: item, selection: $selection)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
            }
        }
    }

    private var worktrees: some View {
        SurfaceSection("Worktrees") {
            if !project.staleWorktrees.isEmpty {
                Button("Prune \(project.staleWorktrees.count) Stale…") {
                    pruneAction = PruneTrigger(count: project.staleWorktrees.count)
                }
                .buttonStyle(.link)
                .font(Theme.Font.caption)
            }
        } content: {
            ForEach(Array(project.worktrees.enumerated()), id: \.offset) { i, tree in
                if i > 0 { RowDivider() }
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tree.branch ?? "detached").font(Theme.Font.bodyStrong)
                        Text(tree.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if tree.isMain { Badge(text: "Main", tint: .secondary) }
                    if tree.isPrunable { Badge(text: "Folder missing", tint: Theme.Status.caution) }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }

    private var archiveCard: some View {
        let allowed = state.canArchive(project)
        return HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "archivebox").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Archive this project").font(Theme.Font.bodyStrong)
                Text(allowed
                     ? "Zip it without build output, check the zip, then move the folder to the Trash."
                     : "This folder holds other projects, so it can't be archived as one.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Archive…") { showArchive = true }.disabled(!allowed)
        }
        .cardStyle()
    }

    private func openInTerminal() {
        NSWorkspace.shared.open([project.url],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct PruneTrigger: Identifiable {
    let id = UUID()
    let count: Int
}

// MARK: - Archive sheet

private struct ArchiveSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let project: DevProject
    let onFinished: (Bool) -> Void

    @State private var projectBytes: Int64?
    @State private var working = false
    @State private var result: (zip: URL, outcome: DeletionOutcome)?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if let result { done(result) } else { plan }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 560)
        .background(Theme.canvas)
        .task {
            let url = project.url
            let size = await Task.detached { DiskScanner.allocatedSize(of: url) }.value
            projectBytes = size
        }
    }

    @ViewBuilder
    private var plan: some View {
        Text("Archive \(project.name)?").font(.system(size: 17, weight: .semibold))
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            step(1, "Zip the project into \(state.archiveDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")), leaving out \(project.artifactBytes.formattedBytes) of build output.")
            step(2, "Check the zip opens cleanly.")
            step(3, "Move the project folder\(projectBytes.map { " (\($0.formattedBytes))" } ?? "") to the Trash. Nothing is moved if the zip fails.")
        }
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Status.caution)
                }
            }
        }
        if let errorText {
            Label(errorText, systemImage: "xmark.octagon.fill")
                .font(Theme.Font.caption).foregroundStyle(Theme.Status.blocked)
        }
        HStack {
            Button("Change Folder…") { chooseFolder() }.buttonStyle(.link).font(Theme.Font.caption)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                Task { await run() }
            } label: {
                if working { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Archiving") } }
                else { Text("Archive") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(working || projectBytes == nil)
        }
        .controlSize(.large)
    }

    private var warnings: [String] {
        var w: [String] = []
        if project.isDirty { w.append("Has uncommitted changes. They're kept in the zip.") }
        if let n = project.unpushedCommits, n > 0 { w.append("\(n) commit\(n == 1 ? "" : "s") not pushed. They're kept in the zip's .git.") }
        if project.unpushedCommits == nil { w.append("No upstream branch. The zip will be the only copy outside the Trash.") }
        return w
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text("\(n)").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
            Text(text).font(Theme.Font.body)
        }
    }

    @ViewBuilder
    private func done(_ r: (zip: URL, outcome: DeletionOutcome)) -> some View {
        Image(systemName: r.outcome.trashed.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(r.outcome.trashed.isEmpty ? Theme.Status.caution : Theme.accent)
        Text(r.outcome.trashed.isEmpty ? "Archived, but the folder stayed" : "\(project.name) archived")
            .font(.system(size: 20, weight: .semibold))
        let zipSize = (try? r.zip.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0).formattedBytes } ?? ""
        Text("\(r.zip.lastPathComponent)  \(zipSize)").font(Theme.Font.body).foregroundStyle(.secondary)
        if let skipped = r.outcome.skipped.first {
            Text(skipped.reason).font(Theme.Font.caption).foregroundStyle(Theme.Status.caution)
        } else {
            Text("The project folder is in the Trash until you empty it.").font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button("Show Archive") { showInFinder(r.zip) }
            Spacer()
            Button("Done") {
                onFinished(!r.outcome.trashed.isEmpty)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }

    private func run() async {
        working = true
        errorText = nil
        defer { working = false }
        do {
            result = try await state.archive(project, projectBytes: projectBytes ?? 0)
        } catch {
            errorText = (error as? ProjectArchiver.Failure)?.description ?? error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = state.archiveDirectory
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { state.archiveDirectory = url }
    }
}

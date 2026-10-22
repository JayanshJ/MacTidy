import SwiftUI
import CoreKit

struct DuplicatesView: View {
    /// Manual = pick folders with Add Folder…. Whole computer = scan the
    /// curated user-data roots (Documents, Downloads, Desktop, …) with
    /// system/build/hidden noise excluded, so the user can find dupes
    /// across their own files without drowning in macOS's legitimate
    /// duplicates.
    enum Mode: String, CaseIterable, Identifiable {
        case manual = "Manual folders"
        case wholeComputer = "Whole computer"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .manual
    @State private var roots: [URL] = []
    @State private var sets: [DuplicateSet] = []
    @State private var hasScanned = false
    @State private var isScanning = false
    @State private var status = ""
    @State private var selection = Set<UUID>()
    @State private var sheetPlan: DeletionPlan?
    @State private var showDedupSheet = false
    @State private var scanTask: Task<Void, Never>?

    /// Sets where distinct physical copies exist — clone dedup can help.
    private var dedupableSets: [DuplicateSet] {
        sets.filter { $0.physicalGroups.count > 1 }
    }

    /// Roots effective for the current mode: user-picked folders in manual
    /// mode, the curated user-data set in whole-computer mode.
    private var effectiveRoots: [URL] {
        mode == .wholeComputer ? DuplicateFinder.defaultUserRoots() : roots
    }

    /// Min file size for the scan. Whole-computer scans use a 1 MB floor so
    /// tiny config/text duplicates the user doesn't care about don't drown
    /// the results; manual mode keeps the 1-byte floor.
    private var effectiveMinSize: Int64 {
        mode == .wholeComputer ? 1_048_576 : 1
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
        }
        .background(Theme.canvas)
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Trash duplicate copies?",
                                      plan: plan,
                                      extraAllowedRoots: effectiveRoots) { _ in
                selection.removeAll()
                scan()
            }
        }
        .sheet(isPresented: $showDedupSheet) {
            DedupConfirmationSheet(sets: dedupableSets,
                                   extraAllowedRoots: effectiveRoots) {
                selection.removeAll()
                scan()
            }
        }
        .onDisappear { scanTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            PageHeader(title: "Duplicates",
                       subtitle: "Files compared by content, not name. Clones that already share disk space don\u{2019}t count as waste.") {
                if isScanning {
                    Button("Cancel") { scanTask?.cancel() }
                }
                Button {
                    scan()
                } label: {
                    if isScanning {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Scanning") }
                    } else {
                        Text("Find Duplicates")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(effectiveRoots.isEmpty || isScanning)
            }
            HStack(spacing: Theme.Spacing.md) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if mode == .manual {
                    ForEach(roots, id: \.self) { root in
                        HStack(spacing: 5) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(root.lastPathComponent)
                            Button { roots.removeAll { $0 == root } } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                        .font(Theme.Font.caption)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                        .help(root.path)
                    }
                    Button("Add Folder…") { addFolder() }
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                } else {
                    Text("Documents, Downloads, Desktop, media folders and iCloud Drive. Hidden, system and build files are skipped, and so is anything under 1 MB.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text(status).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sets.isEmpty {
            EmptyStateView(symbol: "doc.on.doc",
                           title: hasScanned ? "No duplicates found" : "Choose where to look",
                           message: hasScanned
                               ? "Every file in these folders is unique."
                               : (mode == .manual ? "Add one or more folders, then find duplicates." : "Find duplicates across your personal folders."))
                .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: Theme.Spacing.md) {
                    Text("\(sets.reduce(0) { $0 + $1.wastedBytes }.formattedBytes) wasted in \(sets.count) set\(sets.count == 1 ? "" : "s")")
                        .font(Theme.Font.bodyStrong)
                    Spacer()
                    Button(allSelected ? "Deselect All" : "Select Extras") {
                        let wasAll = allSelected
                        selection.removeAll()
                        if !wasAll {
                            // One copy per set, never all of them.
                            for set in sets { if let first = set.files.first { selection.insert(first.id) } }
                        }
                    }
                    .help("Select one extra copy from each set. One copy is always kept.")
                    Button("Replace with Clones…") { showDedupSheet = true }
                        .disabled(dedupableSets.isEmpty)
                        .help("Keep every path working while the space comes back: extra copies become APFS clones.")
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, Theme.Spacing.md)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        ForEach(sets) { set in setSection(set) }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, Theme.Spacing.xl)
                }
                if fullySelectedSetExists {
                    Label("Keep at least one copy of every set. Deselect one to continue.", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Status.blocked)
                        .padding(.vertical, Theme.Spacing.sm)
                }
                SelectionFooter(
                    selectedCount: selection.count,
                    selectedBytes: selectedItems.reduce(0) { $0 + $1.sizeBytes },
                    buttonTitle: "Move Copies to Trash…",
                    disabled: fullySelectedSetExists
                ) {
                    sheetPlan = DeletionPlan(items: selectedItems)
                }
            }
        }
    }

    private var allSelected: Bool {
        let all = sets.flatMap(\.files)
        return !all.isEmpty && all.allSatisfy { selection.contains($0.id) }
    }

    private func setSection(_ set: DuplicateSet) -> some View {
        SurfaceSection("\(set.files.count) copies of \(set.fileSizeBytes.formattedBytes)"
                       + (set.alreadySharedCount > 0 ? ", \(set.alreadySharedCount) already cloned" : "")) {
            Text("\(set.wastedBytes.formattedBytes) wasted")
                .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
        } content: {
            ForEach(Array(set.physicalGroups.enumerated()), id: \.offset) { groupIndex, group in
                ForEach(Array(group.enumerated()), id: \.element.id) { fileIndex, item in
                    if groupIndex > 0 || fileIndex > 0 { RowDivider(inset: 70) }
                    HStack(spacing: Theme.Spacing.sm) {
                        ScanItemRow(item: item, selection: $selection)
                        if fileIndex > 0 {
                            Badge(text: "Clone", tint: Theme.accent)
                                .help("Shares its disk blocks with the copy above, so it takes no extra space.")
                        } else if groupIndex > 0 {
                            Badge(text: "Extra copy", tint: Theme.Status.caution)
                                .help("An independent copy that takes its own space.")
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
    }

    private var selectedItems: [ScanItem] {
        sets.flatMap(\.files).filter { selection.contains($0.id) }
    }

    /// True when the user has (accidentally) selected every copy in some
    /// set — trashing all of them would lose the content entirely.
    private var fullySelectedSetExists: Bool {
        sets.contains { set in
            !set.files.isEmpty && set.files.allSatisfy { selection.contains($0.id) }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to scan for duplicate files"
        if panel.runModal() == .OK {
            for url in panel.urls where !roots.contains(url) {
                roots.append(url)
            }
        }
    }

    private func scan() {
        scanTask?.cancel()
        isScanning = true
        selection.removeAll()
        status = "Listing files…"
        let targets = effectiveRoots
        let minSize = effectiveMinSize
        scanTask = Task {
            let found = await DuplicateFinder.find(in: targets, minFileSize: minSize) { message in
                Task { @MainActor in status = message }
            }
            if Task.isCancelled { return }
            sets = found
            hasScanned = true
            isScanning = false
        }
    }
}

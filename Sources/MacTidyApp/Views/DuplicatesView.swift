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
            rootsBar
            Divider()
            content
        }
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

    private var rootsBar: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .help(mode == .wholeComputer
                    ? "Scan your Documents, Downloads, Desktop, and media folders — system and build files are excluded."
                    : "Pick specific folders to compare for duplicates.")
                Spacer()
                Button {
                    scan()
                } label: {
                    if isScanning {
                        Label("Scanning…", systemImage: "hourglass")
                    } else {
                        Label("Find Duplicates", systemImage: "doc.on.doc")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(effectiveRoots.isEmpty || isScanning)
                if isScanning {
                    Button("Cancel") { scanTask?.cancel() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            HStack {
                if mode == .manual {
                    if roots.isEmpty {
                        Text("Pick the folders to compare — duplicates are only searched where you point.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(roots, id: \.self) { root in
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                Text(root.lastPathComponent)
                                Button {
                                    roots.removeAll { $0 == root }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                            .help(root.path)
                        }
                    }
                } else {
                    Text("Scanning your Documents, Downloads, Desktop, Movies, Music, Pictures, and iCloud Drive. System, hidden, and build files are skipped. Files under 1 MB are ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if mode == .manual {
                    Button("Add Folder…") { addFolder() }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack(spacing: 8) {
                ProgressView()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sets.isEmpty {
            ContentUnavailableView(
                hasScanned ? "No duplicates found" : "No scan yet",
                systemImage: "doc.on.doc",
                description: Text(hasScanned
                    ? "Every file in the selected folders is unique by content."
                    : "Add folders and run a scan. Files are compared by content (SHA-256), not by name.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(sets.count) duplicate set\(sets.count == 1 ? "" : "s") · \(sets.reduce(0) { $0 + $1.wastedBytes }.formattedBytes) wasted")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !sets.isEmpty {
                        Button {
                            let allItems = sets.flatMap(\.files)
                            let allSelected = allItems.allSatisfy { selection.contains($0.id) }
                            selection.removeAll()
                            if !allSelected {
                                // Select one copy per set, never all (would
                                // delete the only remaining copy of content).
                                for set in sets {
                                    if let first = set.files.first {
                                        selection.insert(first.id)
                                    }
                                }
                            }
                        } label: {
                            let allSelected = sets.flatMap(\.files).allSatisfy { selection.contains($0.id) }
                            Label(allSelected ? "Deselect All" : "Select Extras",
                                  systemImage: allSelected ? "circle" : "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Select one extra copy from each set (always keeps one copy).")
                    }
                    Button {
                        showDedupSheet = true
                    } label: {
                        Label("Deduplicate — Keep All Files…", systemImage: "arrow.triangle.merge")
                    }
                    .disabled(dedupableSets.isEmpty)
                    .help("Replace extra copies with APFS clones: every path keeps working, the space comes back.")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                List {
                    ForEach(sets) { set in
                        setSection(set)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                SelectionFooter(
                    selectedCount: selection.count,
                    selectedBytes: selectedItems.reduce(0) { $0 + $1.sizeBytes },
                    buttonTitle: "Trash Selected Copies…",
                    disabled: fullySelectedSetExists
                ) {
                    sheetPlan = DeletionPlan(items: selectedItems)
                }
                .overlay(alignment: .top) {
                    if fullySelectedSetExists {
                        Text("At least one copy of every set must be kept — deselect one.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func setSection(_ set: DuplicateSet) -> some View {
        Section {
            ForEach(Array(set.physicalGroups.enumerated()), id: \.offset) { groupIndex, group in
                ForEach(Array(group.enumerated()), id: \.element.id) { fileIndex, item in
                    HStack {
                        ScanItemRow(item: item, selection: $selection)
                        if fileIndex > 0 {
                            Badge(text: "Clone", tint: Theme.Status.good)
                                .help("Already shares its on-disk blocks with the copy above — takes no extra space.")
                        } else if groupIndex > 0 {
                            Badge(text: "Extra copy", tint: Theme.Status.caution)
                                .help("Independent second copy — this one actually wastes space.")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("\(set.files.count) copies"
                     + (set.alreadySharedCount > 0 ? " (\(set.alreadySharedCount) cloned)" : "")
                     + " · \(set.fileSizeBytes.formattedBytes) each")
                Spacer()
                Text("\(set.wastedBytes.formattedBytes) wasted").monospacedDigit()
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

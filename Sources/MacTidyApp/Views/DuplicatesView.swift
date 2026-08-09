import SwiftUI
import CoreKit

struct DuplicatesView: View {
    @State private var roots: [URL] = []
    @State private var sets: [DuplicateSet] = []
    @State private var hasScanned = false
    @State private var isScanning = false
    @State private var status = ""
    @State private var selection = Set<UUID>()
    @State private var sheetPlan: DeletionPlan?
    @State private var showDedupSheet = false

    /// Sets where distinct physical copies exist — clone dedup can help.
    private var dedupableSets: [DuplicateSet] {
        sets.filter { $0.physicalGroups.count > 1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            rootsBar
            Divider()
            content
        }
        .navigationTitle("Duplicates")
        .sheet(item: $sheetPlan) { plan in
            DeletionConfirmationSheet(title: "Trash duplicate copies?",
                                      plan: plan,
                                      extraAllowedRoots: roots) { outcome in
                if !outcome.dryRun {
                    selection.removeAll()
                    scan()
                }
            }
        }
        .sheet(isPresented: $showDedupSheet) {
            DedupConfirmationSheet(sets: dedupableSets,
                                   extraAllowedRoots: roots) { dryRun in
                if !dryRun {
                    selection.removeAll()
                    scan()
                }
            }
        }
    }

    private var rootsBar: some View {
        HStack {
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
            Spacer()
            Button("Add Folder…") { addFolder() }
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
            .disabled(roots.isEmpty || isScanning)
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
        } else {
            HStack {
                Text("\(sets.count) duplicate set\(sets.count == 1 ? "" : "s") · \(sets.reduce(0) { $0 + $1.wastedBytes }.formattedBytes) wasted")
                    .foregroundStyle(.secondary)
                Spacer()
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

    @ViewBuilder
    private func setSection(_ set: DuplicateSet) -> some View {
        Section {
            ForEach(Array(set.physicalGroups.enumerated()), id: \.offset) { groupIndex, group in
                ForEach(Array(group.enumerated()), id: \.element.id) { fileIndex, item in
                    HStack {
                        ScanItemRow(item: item, selection: $selection)
                        if fileIndex > 0 {
                            Text("CLONE — takes no extra space")
                                .font(.caption2.bold())
                                .padding(.horizontal, 4)
                                .background(.green.opacity(0.25), in: Capsule())
                                .help("Already shares its on-disk blocks with the copy above.")
                        } else if groupIndex > 0 {
                            Text("EXTRA COPY")
                                .font(.caption2.bold())
                                .padding(.horizontal, 4)
                                .background(.orange.opacity(0.25), in: Capsule())
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
        isScanning = true
        selection.removeAll()
        status = "Listing files…"
        let targets = roots
        Task {
            let found = await DuplicateFinder.find(in: targets) { message in
                Task { @MainActor in status = message }
            }
            sets = found
            hasScanned = true
            isScanning = false
        }
    }
}

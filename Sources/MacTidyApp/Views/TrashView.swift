import SwiftUI
import CoreKit

/// The visible half of the Trash undo: everything MacTidy has moved to the
/// Trash, with per-item Restore (moves it back to its original path) and
/// Dismiss (leaves it in the Trash, just clears the log entry). Nothing here
/// empties the Trash — that's the user's call in Finder.
struct TrashView: View {
    @Environment(AppState.self) private var state
    @State private var errorMessage: String?
    @State private var restoringID: UUID?

    var body: some View {
        Group {
            if state.recentTrashed.isEmpty {
                ContentUnavailableView(
                    "Nothing trashed yet",
                    systemImage: "trash",
                    description: Text("Items MacTidy moves to the Trash appear here for a while, so you can undo with one click.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Recently Trashed")
        .toolbar {
            if !state.recentTrashed.isEmpty {
                Button("Clear List") { state.recentTrashed.forEach { state.dismissTrashed($0) } }
                    .help("Remove all entries from this list (items stay in the Trash).")
            }
        }
        .alert("Restore failed",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .onAppear { state.refreshLogs() }
    }

    private var list: some View {
        List {
            ForEach(sectioned, id: \.0) { section in
                Section {
                    ForEach(section.1) { record in
                        row(record)
                    }
                } header: {
                    HStack {
                        Text(section.0)
                        Spacer()
                        Text(section.1.reduce(0) { $0 + $1.bytes }.formattedBytes)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Records grouped by day, newest first.
    private var sectioned: [(String, [TrashRecord])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: state.recentTrashed) { record in
            cal.startOfDay(for: record.date)
        }
        return grouped.sorted { $0.key > $1.key }.map { (day, records) in
            (day.formatted(date: .complete, time: .omitted), records.sorted { $0.date > $1.date })
        }
    }

    @ViewBuilder
    private func row(_ record: TrashRecord) -> some View {
        HStack {
            Image(systemName: record.kind == .dedup ? "doc.on.doc" : "trash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.original.lastPathComponent).lineLimit(1)
                Text(record.original.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(record.bytes.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            if restoringID == record.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Restore") { restore(record) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button {
                    state.dismissTrashed(record)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss from list (keeps it in the Trash)")
            }
        }
        .contextMenu {
            Button("Show in Finder") { showInFinder(record.original) }
        }
    }

    private func restore(_ record: TrashRecord) {
        restoringID = record.id
        Task {
            do {
                _ = try state.restore(record)
            } catch {
                errorMessage = error.localizedDescription
            }
            await MainActor.run { restoringID = nil }
        }
    }
}
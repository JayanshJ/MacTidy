import SwiftUI
import CoreKit

/// Sheet for creating or editing a scheduled cleanup job. Picks cadence
/// (daily/weekly/monthly), the fire hour, weekday (weekly) or day-of-month
/// (monthly), and the subset of *safe* (`isPreselectable`) categories to
/// auto-trash. Suggest-only categories are deliberately not offered —
/// automated runs never touch node_modules, iOS backups, app state, or
/// arbitrary large files. On save, `nextRun` is recomputed via
/// `SchedulePlanner` so the row shows the next fire immediately.
struct ScheduleEditor: View {
    /// Working copy mutated by the editor; committed to AppState on save.
    @State private var job: ScheduledJob
    private let isNew: Bool
    private let onSave: (ScheduledJob) -> Void
    private let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(job: ScheduledJob, isNew: Bool, onSave: @escaping (ScheduledJob) -> Void, onDelete: @escaping () -> Void) {
        self._job = State(initialValue: job)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var safeCategories: [CoreKit.Category] {
        CoreKit.Category.allCases.filter { $0.isPreselectable }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Repeat", selection: $job.cadence) {
                        ForEach(ScheduleCadence.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper(value: $job.hour, in: 0...23) {
                        Text("At \(String(format: "%02d:00", job.hour))")
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text("MacTidy wakes at this hour via launchd, runs the safe categories below, then quits. The app does not need to be open.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if job.cadence == .weekly {
                    Section("Weekday") {
                        Picker("Weekday", selection: $job.weekday) {
                            ForEach(1...7, id: \.self) { d in
                                Text(weekdayName(d)).tag(d)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } else if job.cadence == .monthly {
                    Section("Day of month") {
                        Stepper(value: $job.dayOfMonth, in: 1...28) {
                            Text("Day \(job.dayOfMonth)")
                        }
                    }
                }

                Section {
                    ForEach(safeCategories, id: \.self) { cat in
                        Toggle(isOn: Binding(
                            get: { job.categories.contains(cat) },
                            set: { on in
                                if on { job.categories.insert(cat) }
                                else { job.categories.remove(cat) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cat.displayName)
                                Text(cat.explanation)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Categories to clean")
                } footer: {
                    if job.categories.isEmpty {
                        Text("Select at least one category.")
                            .font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Only safe-to-auto-clean categories are listed. Suggest-only categories (node_modules, iOS backups, app support, large files) are never run on a schedule.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Text("Delete")
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = job
                    saved.nextRun = SchedulePlanner.nextRun(for: saved, after: Date())
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(job.categories.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 520)
    }

    private func weekdayName(_ d: Int) -> String {
        Calendar.current.shortWeekdaySymbols[safe: d - 1] ?? "\(d)"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
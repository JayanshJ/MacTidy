import SwiftUI
import CoreKit

/// "Why is this big?" for a folder MacTidy has no rule for. Always shows what
/// MacTidy measured itself; the AI's answer sits below it when a provider is
/// set up. Renders plain values, so the parent owns the work.
struct WhyBigSheet: View {
    let folder: URL
    let profile: FolderProfile?
    let answer: ItemExplanation?
    let isAsking: Bool
    let aiAvailable: Bool
    let sendsNames: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Why is \(folder.lastPathComponent) big?").font(.headline).lineLimit(1)
                Text(folder.path).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            ScrollView {
                if let profile {
                    content(profile)
                } else {
                    ProgressView("Looking inside").frame(maxWidth: .infinity).padding(Theme.Spacing.xl)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 520, height: 560)
        .background(Theme.canvas)
    }

    private func content(_ profile: FolderProfile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(profile.summary())
                .font(Theme.Font.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            if aiAvailable {
                SurfaceSection("From your AI provider",
                               footer: sendsNames ? "Sent names, sizes and kinds of file."
                                                  : "Sent sizes and kinds of file. No names left this Mac.") {
                    aiAnswer
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                }
            } else {
                Text("Add an AI provider in Settings to get a likely explanation as well.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            if !profile.children.isEmpty {
                let extra = profile.childCount - profile.children.count
                SurfaceSection("Biggest inside", footer: extra > 0 ? "And \(extra) more." : nil) {
                    rows(profile.children.map { ($0.name, $0.bytes) }, total: profile.totalBytes)
                }
            }
            if !profile.kinds.isEmpty {
                SurfaceSection("Kinds of file", footer: profile.isPartial ? "Counted from the first 100,000 files." : nil) {
                    rows(profile.kinds.map { ($0.kind.rawValue.capitalizedFirst, $0.bytes) }, total: profile.totalBytes)
                }
            }
        }
    }

    @ViewBuilder
    private var aiAnswer: some View {
        if let answer {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                if let verdict = answer.verdict {
                    Image(systemName: verdict.icon)
                        .foregroundStyle(verdict == .safe ? Theme.Status.good : (verdict == .keep ? Theme.Status.blocked : Theme.Status.caution))
                }
                Text(answer.summary).font(Theme.Font.body)
                Spacer(minLength: 0)
            }
        } else if isAsking {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Asking the AI").foregroundStyle(.secondary)
            }
        }
    }

    private func rows(_ entries: [(String, Int64)], total: Int64) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
            if index > 0 { RowDivider() }
            HStack(spacing: Theme.Spacing.md) {
                Text(entry.0).font(Theme.Font.body).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.md)
                Meter(fraction: Double(entry.1) / Double(max(total, 1)), tint: Theme.used).frame(width: 90)
                Text(entry.1.formattedBytes)
                    .font(Theme.Font.body.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

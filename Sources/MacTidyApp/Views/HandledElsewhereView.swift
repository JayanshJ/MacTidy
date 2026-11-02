import SwiftUI
import CoreKit

/// One row on the Overview and the Cleanup page: how much another app or
/// setting manages, and the way to the detail. Shows nothing when there's none.
struct HandledElsewhereLink: View {
    @Environment(AppState.self) private var state
    static let symbol = "arrow.up.forward.app"

    var body: some View {
        let groups = HandledElsewhere.groups(state.elsewhereItems)
        if !groups.isEmpty {
            SurfaceSection("Handled elsewhere", footer: "Other apps and settings manage these, so they aren't counted as cleanable.") {
                Button {
                    state.section = .cleanup
                    state.drilledCategory = nil
                    withAnimation(Theme.ease) { state.showingElsewhere = true }
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: Self.symbol)
                            .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(HandledElsewhere.summary(groups)).font(Theme.Font.bodyStrong).lineLimit(1)
                            Text("\(state.elsewhereItems.count) item\(state.elsewhereItems.count == 1 ? "" : "s")")
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Spacing.lg)
                        Text(groups.reduce(0) { $0 + $1.bytes }.formattedBytes)
                            .font(Theme.Font.bodyStrong.monospacedDigit())
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }
}

/// Everything handled elsewhere, by owner: size, an honest sentence and a
/// button to the right place. Same rows as a category, minus any way to select
/// them: there's no footer and nothing here can start a cleanup.
struct HandledElsewhereDetail: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let groups = HandledElsewhere.groups(state.elsewhereItems)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Button {
                    withAnimation(Theme.ease) { state.showingElsewhere = false }
                } label: {
                    Label("Cleanup", systemImage: "chevron.left").font(Theme.Font.body)
                }
                .buttonStyle(.link)
                PageHeader(title: "Handled elsewhere",
                           subtitle: "\(state.elsewhereItems.count) item\(state.elsewhereItems.count == 1 ? "" : "s")  ·  \(groups.reduce(0) { $0 + $1.bytes }.formattedBytes)") {}
                Text("MacTidy measures these but doesn't clean them. The app or setting that owns them is the right place to remove them, so they aren't counted as cleanable.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Theme.hairline).frame(height: 1)
            if groups.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "Nothing here now")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        ForEach(groups) { section($0) }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.vertical, Theme.Spacing.xl)
                }
            }
        }
        .background(Theme.canvas)
    }

    private func section(_ group: HandledElsewhere.Group) -> some View {
        SurfaceSection(group.rule.owner, footer: group.rule.explanation, lazy: true) {
            // A lone row already shows the same size.
            if group.items.count > 1 {
                Text(group.bytes.formattedBytes)
                    .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(group.rule.buttonTitle(appInstalled: state.isAppInstalled(for: group.rule))) {
                state.openElsewhere(group.rule, items: group.items)
            }
            .buttonStyle(.link)
            .font(Theme.Font.caption)
        } content: {
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider(inset: 48) }
                ScanItemRow(item: item, selection: .constant([]))
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
            }
        }
    }
}

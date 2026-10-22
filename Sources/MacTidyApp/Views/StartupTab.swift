import SwiftUI
import CoreKit

/// Startup Items tab on the dashboard. Lists launch agents/daemons across all
/// three domains with Disable actions. Reuses the existing LaunchItemsAuditor.
struct DashboardStartup: View {
    @Environment(AppState.self) private var state
    @State private var items: [LaunchItem] = []
    @State private var disabledItems: [LaunchItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Page("Login Items",
             subtitle: "Background agents and daemons that start with your Mac. Disabling parks the plist so it can be restored.") {
            Button { reload() } label: {
                if isLoading { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .disabled(isLoading)
        } content: {
            if isLoading && items.isEmpty {
                ProgressView("Reading launch agents").frame(maxWidth: .infinity).padding(Theme.Spacing.xxl)
            }
            ForEach(LaunchItem.Domain.allCases, id: \.self) { domain in
                section(for: domain)
            }
            if !disabledItems.isEmpty {
                SurfaceSection("Disabled by MacTidy") {
                    ForEach(Array(disabledItems.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { RowDivider() }
                        row(item, action: .restore)
                    }
                }
            }
        }
        .onAppear { if items.isEmpty { reload() } }
        .alert("Startup item change failed",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func section(for domain: LaunchItem.Domain) -> some View {
        let domainItems = items.filter { $0.domain == domain }
        if !domainItems.isEmpty {
            SurfaceSection(domain.rawValue,
                           footer: domain.requiresAdmin ? "Changing these asks for your administrator password." : nil) {
                ForEach(Array(domainItems.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { RowDivider() }
                    row(item, action: .disable)
                }
            }
        }
    }

    private enum RowAction { case disable, restore }

    @ViewBuilder
    private func row(_ item: LaunchItem, action: RowAction?) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Circle()
                .fill(item.isLoaded ? Theme.accent : Theme.track)
                .frame(width: 7, height: 7)
                .help(item.isLoaded ? "Running now" : "Not running")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(item.label).font(Theme.Font.bodyStrong).lineLimit(1)
                    if item.runAtLoad == true { Badge(text: "At login", tint: .secondary) }
                }
                if let program = item.program {
                    Text(program).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Theme.Spacing.lg)
            switch action {
            case .disable: Button("Disable") { disable(item) }
            case .restore: Button("Restore") { restore(item) }
            case nil: EmptyView()
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func reload() {
        isLoading = true
        Task {
            let (audited, parked) = await Task.detached {
                (LaunchItemsAuditor.audit(), LaunchItemsAuditor.disabledItems())
            }.value
            items = audited; disabledItems = parked; isLoading = false
        }
    }

    private func disable(_ item: LaunchItem) {
        do { try LaunchItemsAuditor.disable(item); reload() }
        catch { errorMessage = error.localizedDescription }
    }

    private func restore(_ item: LaunchItem) {
        do { try LaunchItemsAuditor.restore(item); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}
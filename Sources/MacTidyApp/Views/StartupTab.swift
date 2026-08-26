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
        VStack(spacing: 0) {
            HStack {
                Text("Startup Items").font(.title3.bold())
                Spacer()
                Button { reload() } label: {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Label("Rescan", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isLoading)
            }
            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
            Divider()
            List {
                ForEach(LaunchItem.Domain.allCases, id: \.self) { domain in
                    section(for: domain)
                }
                if !disabledItems.isEmpty {
                    Section("Disabled by MacTidy") {
                        ForEach(disabledItems) { item in row(item, action: .restore) }
                    }
                }
            }
            .overlay { if isLoading { ProgressView("Reading launchd plists…") } }
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
        Section {
            if domainItems.isEmpty { Text("None found").foregroundStyle(.tertiary) }
            ForEach(domainItems) { item in row(item, action: .disable) }
        } header: { Text(domain.rawValue) }
        footer: {
            if domain.requiresAdmin {
                Text("Needs admin rights — macOS will prompt for your password.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private enum RowAction { case disable, restore }

    @ViewBuilder
    private func row(_ item: LaunchItem, action: RowAction?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).fontWeight(.medium).lineLimit(1)
                    if item.isLoaded { Badge(text: "Loaded", tint: Theme.Status.good, filled: true) }
                    if item.runAtLoad == true { Badge(text: "Runs at login", tint: .blue) }
                    if item.domain.requiresAdmin { Badge(text: "Admin", tint: Theme.Status.caution) }
                }
                if let program = item.program {
                    Text(program).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            switch action {
            case .disable: Button("Disable") { disable(item) }
            case .restore: Button("Restore") { restore(item) }
            case nil: EmptyView()
            }
        }
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
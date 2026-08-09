import SwiftUI
import CoreKit

struct StartupItemsView: View {
    @State private var items: [LaunchItem] = []
    @State private var disabledItems: [LaunchItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(LaunchItem.Domain.allCases, id: \.self) { domain in
                section(for: domain)
            }
            if !disabledItems.isEmpty {
                Section("Disabled by MacTidy") {
                    ForEach(disabledItems) { item in
                        row(item, action: .restore)
                    }
                }
            }
        }
        .overlay {
            if isLoading { ProgressView("Reading launchd plists…") }
        }
        .navigationTitle("Startup Items")
        .toolbar {
            Button {
                reload()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .onAppear { if items.isEmpty { reload() } }
        .alert("Startup item change failed",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func section(for domain: LaunchItem.Domain) -> some View {
        let domainItems = items.filter { $0.domain == domain }
        Section {
            if domainItems.isEmpty {
                Text("None found").foregroundStyle(.tertiary)
            }
            ForEach(domainItems) { item in
                row(item, action: domain.isToggleable ? .disable : nil)
            }
        } header: {
            Text(domain.rawValue)
        } footer: {
            if !domain.isToggleable {
                Text("System items need admin rights to change — shown read-only in this version.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                    if item.isLoaded {
                        Text("LOADED")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .background(.green.opacity(0.25), in: Capsule())
                    }
                    if item.runAtLoad == true {
                        Text("RUNS AT LOGIN")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .background(.blue.opacity(0.2), in: Capsule())
                    }
                }
                if let program = item.program {
                    Text(program)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                showInFinder(item.url)
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Show plist in Finder")

            switch action {
            case .disable:
                Button("Disable") { disable(item) }
            case .restore:
                Button("Restore") { restore(item) }
            case nil:
                EmptyView()
            }
        }
    }

    private func reload() {
        isLoading = true
        Task {
            let (audited, parked) = await Task.detached {
                (LaunchItemsAuditor.audit(), LaunchItemsAuditor.disabledItems())
            }.value
            items = audited
            disabledItems = parked
            isLoading = false
        }
    }

    private func disable(_ item: LaunchItem) {
        do {
            try LaunchItemsAuditor.disable(item)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ item: LaunchItem) {
        do {
            try LaunchItemsAuditor.restore(item)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

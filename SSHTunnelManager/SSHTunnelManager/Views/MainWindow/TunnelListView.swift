import SwiftUI

@MainActor
struct TunnelListView: View {
    @Environment(TunnelManager.self) private var tunnelManager
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(tunnelManager.items) { item in
                switch item {
                case .tunnel(let tunnel):
                    TunnelRow(tunnel: tunnel)
                        .tag(tunnel.id)
                        .contextMenu {
                            Button {
                                tunnelManager.moveItemUp(id: tunnel.id)
                            } label: {
                                Label("Move Up", systemImage: "arrow.up")
                            }
                            .disabled(!tunnelManager.canMoveUp(id: tunnel.id))

                            Button {
                                tunnelManager.moveItemDown(id: tunnel.id)
                            } label: {
                                Label("Move Down", systemImage: "arrow.down")
                            }
                            .disabled(!tunnelManager.canMoveDown(id: tunnel.id))

                            Divider()

                            Button {
                                let clone = tunnelManager.cloneTunnel(tunnel)
                                selection = clone.id
                            } label: {
                                Label("Clone", systemImage: "doc.on.doc")
                            }

                            Button {
                                let divider = tunnelManager.addDivider(after: tunnel.id)
                                selection = divider.id
                            } label: {
                                Label("Add Divider Below", systemImage: "rectangle.dashed")
                            }

                            Divider()

                            Button(role: .destructive) {
                                if selection == tunnel.id { selection = nil }
                                tunnelManager.deleteTunnel(tunnel)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                case .divider(let divider):
                    DividerRow(divider: divider)
                        .tag(divider.id)
                        .contextMenu {
                            Button {
                                tunnelManager.moveItemUp(id: divider.id)
                            } label: {
                                Label("Move Up", systemImage: "arrow.up")
                            }
                            .disabled(!tunnelManager.canMoveUp(id: divider.id))

                            Button {
                                tunnelManager.moveItemDown(id: divider.id)
                            } label: {
                                Label("Move Down", systemImage: "arrow.down")
                            }
                            .disabled(!tunnelManager.canMoveDown(id: divider.id))

                            Divider()

                            Button(role: .destructive) {
                                if selection == divider.id { selection = nil }
                                tunnelManager.deleteDivider(divider.id)
                            } label: {
                                Label("Delete Divider", systemImage: "trash")
                            }
                        }
                }
            }
            .onMove { tunnelManager.moveItems(from: $0, to: $1) }
            .onDelete(perform: deleteItems)
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let divider = tunnelManager.addDivider(after: selection)
                    selection = divider.id
                } label: {
                    Image(systemName: "rectangle.dashed")
                }
                .help("Add a group divider")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    tunnelManager.addTunnel()
                    selection = tunnelManager.tunnels.last?.id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add new tunnel")
            }
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        // Resolve items before mutating, since deletes shift indices.
        let targets = offsets.map { tunnelManager.items[$0] }
        for item in targets {
            if selection == item.id { selection = nil }
            switch item {
            case .tunnel(let tunnel):
                tunnelManager.deleteTunnel(tunnel)
            case .divider(let divider):
                tunnelManager.deleteDivider(divider.id)
            }
        }
    }
}

@MainActor
struct TunnelRow: View {
    let tunnel: Tunnel
    @Environment(TunnelManager.self) private var tunnelManager

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(status: tunnelManager.status(for: tunnel), size: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(tunnel.mappingsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A standalone group divider row. Select it to edit its name in the detail
/// pane; reorder it with the ↑↓ buttons or by dragging.
@MainActor
struct DividerRow: View {
    let divider: GroupDivider

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.horizontal.3")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if divider.title.isEmpty {
                Text("New group")
                    .font(.caption2)
                    .italic()
                    .foregroundStyle(.tertiary)
            } else {
                Text(divider.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    TunnelListView(selection: .constant(nil))
        .environment(TunnelManager())
        .frame(width: 250)
}

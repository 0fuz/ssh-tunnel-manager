import SwiftUI

@MainActor
struct MenuBarView: View {
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tunnelManager.tunnels.isEmpty {
                Text("No tunnels configured")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(tunnelManager.items.grouped()) { group in
                    // Tunnels before the first divider (title == nil) stay flat;
                    // every named/divided group gets a header with a master toggle.
                    if let title = group.title {
                        GroupHeaderRow(title: title, tunnels: group.tunnels)
                    }
                    ForEach(group.tunnels) { tunnel in
                        TunnelMenuItem(tunnel: tunnel)
                    }
                }
            }

            Divider()
                .padding(.vertical, 4)

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings...")
                    Spacer()
                    Text("⌘,")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .frame(minWidth: 280, maxWidth: 400)
        .fixedSize(horizontal: true, vertical: false)
        // After the sizing modifiers, so the resizer sees the final footprint.
        .background(MenuBarWindowResizer())
    }
}

@MainActor
struct TunnelMenuItem: View {
    let tunnel: Tunnel
    @Environment(TunnelManager.self) private var tunnelManager

    private var status: ConnectionStatus {
        tunnelManager.status(for: tunnel)
    }

    private var isOn: Bool {
        status == .connected || status == .connecting
    }

    private var lastError: String? {
        tunnelManager.lastError(for: tunnel)
    }

    private var statusColor: Color {
        if lastError != nil { return .red }
        switch status {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        }
    }

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.name)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // On error, show the reason here so the tray is self-explanatory
                // without relying on a hover tooltip.
                if let lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if lastError == nil {
                Text(tunnel.localPortsSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { _ in tunnelManager.toggle(tunnel: tunnel) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .help(lastError ?? "")
    }
}

/// Group header in the tray: name + divider line + one master toggle that
/// connects or disconnects every tunnel in the group at once.
@MainActor
struct GroupHeaderRow: View {
    let title: String
    let tunnels: [Tunnel]
    @Environment(TunnelManager.self) private var tunnelManager

    private var isOn: Bool {
        tunnelManager.isGroupActive(tunnels)
    }

    var body: some View {
        HStack(spacing: 6) {
            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(height: 1)

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { _ in tunnelManager.toggleGroup(tunnels) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help("Toggle all tunnels in this group")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

#Preview {
    MenuBarView()
        .environment(TunnelManager())
}

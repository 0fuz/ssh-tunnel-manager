import SwiftUI

@MainActor
struct TunnelDetailView: View {
    let tunnel: Tunnel
    @Environment(TunnelManager.self) private var tunnelManager
    @FocusState private var focusedField: Field?

    @State private var editedTunnel: Tunnel
    @State private var hasChanges = false

    enum Field: Hashable {
        case name, host, port, identityFile, alias
        case mappingLocalHost(UUID), mappingLocalPort(UUID)
        case mappingRemoteHost(UUID), mappingRemotePort(UUID)
        case connectTimeout, aliveInterval, aliveCountMax
    }

    init(tunnel: Tunnel) {
        self.tunnel = tunnel
        self._editedTunnel = State(initialValue: tunnel)
    }

    private var status: ConnectionStatus {
        tunnelManager.status(for: tunnel)
    }

    private var statusText: String {
        switch status {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        }
    }

    private var statusColor: Color {
        switch status {
        case .disconnected: return .secondary
        case .connecting: return .yellow
        case .connected: return .green
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    StatusIndicator(status: status)
                    Text(statusText)
                        .foregroundStyle(statusColor)

                    Spacer()

                    Button(status != .disconnected ? "Disconnect" : "Connect") {
                        if hasChanges {
                            saveChanges()
                        }
                        tunnelManager.toggle(tunnel: editedTunnel)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(status != .disconnected ? .red : .green)
                }

                UsageRow(label: "SSH", value: sshCommand(for: editedTunnel))
            } header: {
                Text("Status")
            }

            Section {
                TextField("Name", text: $editedTunnel.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
            } header: {
                Text("General")
            }

            Section {
                Picker("Mode", selection: $editedTunnel.useAlias) {
                    Text("Host").tag(false)
                    Text("SSH Alias").tag(true)
                }
                .pickerStyle(.segmented)

                if editedTunnel.useAlias {
                    LabeledContent("Alias") {
                        TextField("my-server", text: $editedTunnel.host)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .focused($focusedField, equals: .alias)
                    }

                    Text("Uses ~/.ssh/config alias (no -i flag needed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Host") {
                        HStack(spacing: 4) {
                            TextField("user@server.com", text: $editedTunnel.host)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .focused($focusedField, equals: .host)
                            Text(":")
                                .foregroundStyle(.secondary)
                            TextField("", value: $editedTunnel.port, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .labelsHidden()
                                .focused($focusedField, equals: .port)
                        }
                    }

                    TextField("Identity File (optional)", text: Binding(
                        get: { editedTunnel.identityFile ?? "" },
                        set: { editedTunnel.identityFile = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .identityFile)

                    Text("e.g., ~/.ssh/id_rsa")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("SSH Connection")
            }

            Section {
                ForEach($editedTunnel.portMappings) { $mapping in
                    PortMappingEditor(
                        mapping: $mapping,
                        focusedField: $focusedField,
                        canRemove: editedTunnel.portMappings.count > 1,
                        onRemove: { removeMapping(mapping.id) }
                    )
                }

                Button {
                    editedTunnel.portMappings.append(PortMapping(
                        localPort: nextLocalPort(),
                        remotePort: nextLocalPort()
                    ))
                } label: {
                    Label("Add Port Mapping", systemImage: "plus")
                }
            } header: {
                Text("Port Forwarding")
            } footer: {
                Text("Each mapping adds a -L (local forward) or -D (SOCKS proxy) flag to the SSH command.")
            }

            Section {
                Toggle("Auto-connect on launch", isOn: $editedTunnel.autoConnect)
            } header: {
                Text("Options")
            }

            Section {
                LabeledContent("Connect Timeout") {
                    HStack(spacing: 4) {
                        TextField(
                            "default",
                            value: Binding(
                                get: { editedTunnel.connectTimeout ?? 0 },
                                set: { editedTunnel.connectTimeout = $0 > 0 ? $0 : nil }
                            ),
                            format: .number.grouping(.never)
                        )
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 70)
                        .focused($focusedField, equals: .connectTimeout)
                        Text("sec").foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Alive Interval") {
                    HStack(spacing: 4) {
                        TextField(
                            "\(Tunnel.defaultServerAliveInterval)",
                            value: Binding(
                                get: { editedTunnel.serverAliveInterval ?? 0 },
                                set: { editedTunnel.serverAliveInterval = $0 > 0 ? $0 : nil }
                            ),
                            format: .number.grouping(.never)
                        )
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 70)
                        .focused($focusedField, equals: .aliveInterval)
                        Text("sec").foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Alive Count Max") {
                    TextField(
                        "\(Tunnel.defaultServerAliveCountMax)",
                        value: Binding(
                            get: { editedTunnel.serverAliveCountMax ?? 0 },
                            set: { editedTunnel.serverAliveCountMax = $0 > 0 ? $0 : nil }
                        ),
                        format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 70)
                    .focused($focusedField, equals: .aliveCountMax)
                }
            } header: {
                Text("Connection Resilience")
            } footer: {
                Text("Leave blank to use the app default (Alive Interval 30s, Alive Count Max 3). ConnectTimeout has no default — ssh waits indefinitely unless set.")
            }

            if status == .connected {
                Section {
                    ForEach(editedTunnel.portMappings) { mapping in
                        if mapping.forward == .dynamic {
                            UsageRow(label: "Proxy", value: "\(mapping.localHost):\(mapping.localPort)")
                            UsageRow(label: "socks5h", value: "socks5h://\(mapping.localHost):\(mapping.localPort)")
                            UsageRow(label: "socks5", value: "socks5://\(mapping.localHost):\(mapping.localPort)")
                        } else {
                            UsageRow(
                                label: ":\(mapping.localPort)",
                                value: "http://\(mapping.localHost):\(mapping.localPort)"
                            )
                        }
                    }
                } header: {
                    Text("Usage")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = nil
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    saveChanges()
                }
                .disabled(!hasChanges)
            }
        }
        .onChange(of: editedTunnel) { _, _ in
            hasChanges = true
        }
        .onChange(of: tunnel) { _, newValue in
            editedTunnel = newValue
            hasChanges = false
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue != nil && newValue != oldValue && hasChanges {
                saveChanges()
            }
        }
    }

    private func removeMapping(_ id: UUID) {
        editedTunnel.portMappings.removeAll { $0.id == id }
    }

    private func nextLocalPort() -> Int {
        let usedPorts = Set(editedTunnel.portMappings.map(\.localPort))
        var port = (editedTunnel.portMappings.map(\.localPort).max() ?? 8079) + 1
        while usedPorts.contains(port) {
            port += 1
        }
        return port
    }

    private func saveChanges() {
        tunnelManager.updateTunnel(editedTunnel)
        hasChanges = false
    }

    private func sshCommand(for tunnel: Tunnel) -> String {
        var cmd = "ssh -N"
        for mapping in tunnel.portMappings {
            switch mapping.forward {
            case .local:
                cmd += " -L \(mapping.localHost):\(mapping.localPort):\(mapping.remoteHost):\(mapping.remotePort)"
            case .dynamic:
                cmd += " -D \(mapping.localHost):\(mapping.localPort)"
            }
        }
        // Neutralize login-oriented alias directives so this command is safe to
        // copy/paste for a forward (mirrors how the app launches the tunnel).
        cmd += " -o RequestTTY=no -o RemoteCommand=none -o ControlMaster=no -o ControlPath=none"
        cmd += " -o ServerAliveInterval=\(tunnel.serverAliveInterval ?? Tunnel.defaultServerAliveInterval)"
        cmd += " -o ServerAliveCountMax=\(tunnel.serverAliveCountMax ?? Tunnel.defaultServerAliveCountMax)"
        if let connectTimeout = tunnel.connectTimeout {
            cmd += " -o ConnectTimeout=\(connectTimeout)"
        }
        if tunnel.useAlias {
            if tunnel.port != 22 {
                cmd += " -p \(tunnel.port)"
            }
        } else {
            if tunnel.port != 22 {
                cmd += " -p \(tunnel.port)"
            }
            if let identityFile = tunnel.identityFile, !identityFile.isEmpty {
                cmd += " -i \(identityFile)"
            }
        }
        cmd += " \(tunnel.host)"
        return cmd
    }
}

struct PortMappingEditor: View {
    @Binding var mapping: PortMapping
    @FocusState.Binding var focusedField: TunnelDetailView.Field?
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Type", selection: $mapping.forward) {
                Text("Local Forward").tag(ForwardType.local)
                Text("SOCKS Proxy").tag(ForwardType.dynamic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LabeledContent(mapping.forward == .dynamic ? "Listen" : "Local") {
                HStack(spacing: 4) {
                    TextField("Host", text: $mapping.localHost)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focusedField, equals: .mappingLocalHost(mapping.id))
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("", value: $mapping.localPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .labelsHidden()
                        .focused($focusedField, equals: .mappingLocalPort(mapping.id))
                }
            }

            if mapping.forward == .local {
                LabeledContent("Remote") {
                    HStack(spacing: 4) {
                        TextField("Host", text: $mapping.remoteHost)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .focused($focusedField, equals: .mappingRemoteHost(mapping.id))
                        Text(":")
                            .foregroundStyle(.secondary)
                        TextField("", value: $mapping.remotePort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .labelsHidden()
                            .focused($focusedField, equals: .mappingRemotePort(mapping.id))
                    }
                }
            } else {
                Text("SOCKS5 proxy — point your app or system proxy at this address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if canRemove {
                Button("Remove", role: .destructive) {
                    onRemove()
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

struct UsageRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? .green : .secondary)
            .help("Copy to clipboard")
        }
    }
}

#Preview {
    TunnelDetailView(tunnel: Tunnel(
        name: "Test Tunnel",
        host: "user@example.com",
        port: 22,
        portMappings: [
            PortMapping(localPort: 8080, remotePort: 8080),
            PortMapping(localPort: 5432, remotePort: 5432)
        ]
    ))
    .environment(TunnelManager())
    .frame(width: 500, height: 700)
}

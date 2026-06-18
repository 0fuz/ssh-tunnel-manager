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
        case proxyJump
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

    /// Why the tunnel last failed/dropped, while it isn't up. Drives the red
    /// "Failed" state and the reason row below the status line.
    private var lastError: String? {
        tunnelManager.lastError(for: tunnel)
    }

    /// Local ports this tunnel shares with others — checked against the live
    /// edits so the warning updates as you type a port number.
    private var portConflicts: [(port: Int, names: [String])] {
        tunnelManager.localPortConflicts(for: editedTunnel)
            .sorted { $0.key < $1.key }
            .map { (port: $0.key, names: $0.value) }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    StatusIndicator(status: status, isFailed: lastError != nil)
                    Text(lastError != nil ? "Failed" : statusText)
                        .foregroundStyle(lastError != nil ? .red : statusColor)

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

                if let lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
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

                ForEach(portConflicts, id: \.port) { conflict in
                    Label(
                        "Local port \(String(conflict.port)) is also used by \(conflict.names.joined(separator: ", ")). Only one tunnel can bind a port at a time.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            } header: {
                Text("Port Forwarding")
            } footer: {
                Text("Each mapping adds a -L (local forward), -R (remote forward), or -D (SOCKS proxy) flag to the SSH command.")
            }

            Section {
                Toggle("Auto-connect on launch", isOn: $editedTunnel.autoConnect)
            } header: {
                Text("Options")
            }

            Section {
                LabeledContent("Connect Timeout") {
                    HStack(spacing: 4) {
                        TextField("Connect Timeout", text: Binding(
                            get: { editedTunnel.connectTimeout.map(String.init) ?? "" },
                            set: { editedTunnel.connectTimeout = Int($0) }
                        ), prompt: Text("off"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 70)
                        .focused($focusedField, equals: .connectTimeout)
                        .help("Seconds ssh waits to establish the connection before giving up. Blank = wait indefinitely.")
                        Text("sec").foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Alive Interval") {
                    HStack(spacing: 4) {
                        TextField("Alive Interval", text: Binding(
                            get: { editedTunnel.serverAliveInterval.map(String.init) ?? "" },
                            set: { editedTunnel.serverAliveInterval = Int($0) }
                        ), prompt: Text("\(Tunnel.defaultServerAliveInterval)"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 70)
                        .focused($focusedField, equals: .aliveInterval)
                        .help("Seconds between keepalive probes that detect a dead connection. Blank uses the default (\(Tunnel.defaultServerAliveInterval)).")
                        Text("sec").foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Alive Count Max") {
                    TextField("Alive Count Max", text: Binding(
                        get: { editedTunnel.serverAliveCountMax.map(String.init) ?? "" },
                        set: { editedTunnel.serverAliveCountMax = Int($0) }
                    ), prompt: Text("\(Tunnel.defaultServerAliveCountMax)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 70)
                    .focused($focusedField, equals: .aliveCountMax)
                    .help("Drop the connection after this many missed keepalive probes. Blank uses the default (\(Tunnel.defaultServerAliveCountMax)).")
                }
            } header: {
                Text("Connection Resilience")
            } footer: {
                Text("A blank field uses its placeholder default; hover a field for what it does. Connect Timeout is off unless set.")
            }

            Section {
                Toggle("Compression", isOn: $editedTunnel.compression)
                    .help("Compress the data stream (-C). Can help on slow links; costs CPU.")

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Survive brief network drops", isOn: $editedTunnel.disableTCPKeepAlive)
                        .help("Sets TCPKeepAlive=no, so a short outage doesn't tear the connection down at the TCP layer; the Alive Interval probes above handle liveness instead.")
                    Text("Keeps the tunnel up through short outages instead of dropping immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Skip host key check", isOn: $editedTunnel.skipHostKeyCheck)
                        .help("Sets StrictHostKeyChecking=no and UserKnownHostsFile=/dev/null.")
                    Text("For hosts recreated on the same address. Disables protection against a changed/spoofed host — use only on trusted networks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Jump Host") {
                        TextField("e.g. bastion.example.com", text: Binding(
                            get: { editedTunnel.proxyJump ?? "" },
                            set: { editedTunnel.proxyJump = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focusedField, equals: .proxyJump)
                        .help("Adds -J <value>. Hops through one or more intermediate hosts to reach the host above, replacing a manual multi-hop ssh. Multiple hops: user@a,user@b.")
                    }
                    Text("Optional. Leave blank to connect directly. Format matches ssh -J: user@host[:port][,user@host2[:port2]...]")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Advanced")
            }

            if status == .connected {
                Section {
                    ForEach(editedTunnel.portMappings) { mapping in
                        switch mapping.forward {
                        case .dynamic:
                            UsageRow(label: "Proxy", value: "\(mapping.localHost):\(mapping.localPort)")
                            UsageRow(label: "socks5h", value: "socks5h://\(mapping.localHost):\(mapping.localPort)")
                            UsageRow(label: "socks5", value: "socks5://\(mapping.localHost):\(mapping.localPort)")
                        case .remote:
                            UsageRow(
                                label: "R :\(mapping.localPort)",
                                value: "listening on the remote host — forwards to \(mapping.remoteHost):\(mapping.remotePort) here"
                            )
                        case .local:
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
            case .remote:
                cmd += " -R \(mapping.localHost):\(mapping.localPort):\(mapping.remoteHost):\(mapping.remotePort)"
            case .dynamic:
                cmd += " -D \(mapping.localHost):\(mapping.localPort)"
            }
        }
        // Neutralize login-oriented alias directives so this command is safe to
        // copy/paste for a forward (mirrors how the app launches the tunnel).
        cmd += " -o RequestTTY=no -o RemoteCommand=none -o ControlMaster=no -o ControlPath=none"
        cmd += " -o ServerAliveInterval=\(tunnel.serverAliveInterval ?? Tunnel.defaultServerAliveInterval)"
        cmd += " -o ServerAliveCountMax=\(tunnel.serverAliveCountMax ?? Tunnel.defaultServerAliveCountMax)"
        cmd += " -o ConnectionAttempts=2 -o BatchMode=yes"
        if let connectTimeout = tunnel.connectTimeout {
            cmd += " -o ConnectTimeout=\(connectTimeout)"
        }
        if tunnel.compression {
            cmd += " -C"
        }
        if tunnel.disableTCPKeepAlive {
            cmd += " -o TCPKeepAlive=no"
        }
        if tunnel.skipHostKeyCheck {
            cmd += " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        }
        if let proxyJump = tunnel.proxyJump?.trimmingCharacters(in: .whitespaces), !proxyJump.isEmpty {
            cmd += " -J \(proxyJump)"
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
                cmd += " -i \(identityFile) -o IdentitiesOnly=yes"
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
                Text("Remote Forward").tag(ForwardType.remote)
                Text("SOCKS Proxy").tag(ForwardType.dynamic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LabeledContent(mapping.forward == .dynamic ? "Listen" : (mapping.forward == .remote ? "On Remote" : "Local")) {
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

            switch mapping.forward {
            case .local, .remote:
                LabeledContent(mapping.forward == .remote ? "Back to (usually this Mac)" : "Remote") {
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
                if mapping.forward == .remote {
                    Text("The remote host binds this port and forwards what it receives back to the host:port below — usually localhost on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .dynamic:
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

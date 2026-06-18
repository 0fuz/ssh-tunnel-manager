import Foundation

/// How a port mapping forwards traffic.
enum ForwardType: String, Codable, Hashable {
    case local      // ssh -L : a fixed local→remote port forward
    case remote     // ssh -R : a fixed remote→local port forward (the remote
                    // host binds the port; traffic arriving there is sent
                    // back to this Mac)
    case dynamic    // ssh -D : a SOCKS proxy (destinations chosen per request)
}

struct PortMapping: Identifiable, Codable, Hashable {
    var id: UUID
    var forward: ForwardType
    var localHost: String
    var localPort: Int
    var remoteHost: String
    var remotePort: Int

    init(
        id: UUID = UUID(),
        forward: ForwardType = .local,
        localHost: String = "127.0.0.1",
        localPort: Int = 8080,
        remoteHost: String = "127.0.0.1",
        remotePort: Int = 8080
    ) {
        self.id = id
        self.forward = forward
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    enum CodingKeys: String, CodingKey {
        case id, forward, localHost, localPort, remoteHost, remotePort
    }

    // Custom decoder so older configs without `forward` default to .local.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        forward = try c.decodeIfPresent(ForwardType.self, forKey: .forward) ?? .local
        localHost = try c.decode(String.self, forKey: .localHost)
        localPort = try c.decode(Int.self, forKey: .localPort)
        remoteHost = try c.decode(String.self, forKey: .remoteHost)
        remotePort = try c.decode(Int.self, forKey: .remotePort)
    }
}

struct Tunnel: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String           // user@server.com or SSH config alias
    var port: Int              // SSH port (default 22)
    var portMappings: [PortMapping]
    var identityFile: String?  // Path to identity file (~/.ssh/id_rsa)
    var autoConnect: Bool      // Connect on app launch
    var useAlias: Bool         // Use host as SSH config alias (no -i, no -p unless non-22)

    // Connection hardening options. nil means "use the app's default",
    // so existing configs without these keys behave exactly as before.
    var connectTimeout: Int?         // -o ConnectTimeout=N (seconds)
    var serverAliveInterval: Int?    // -o ServerAliveInterval=N (seconds)
    var serverAliveCountMax: Int?    // -o ServerAliveCountMax=N

    // Simple on/off connection options. Unlike the Int? options above these
    // have an unambiguous "off" state, so a plain Bool (defaulting to false)
    // is enough — no separate "use app default" case to represent.
    var compression: Bool          // -C (compress the data stream)
    var disableTCPKeepAlive: Bool  // -o TCPKeepAlive=no — keep the tunnel up through brief
                                   // outages; rely on the ServerAlive probes above instead of
                                   // TCP-level dead-path teardown. (ssh defaults to yes.)
    var skipHostKeyCheck: Bool     // -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null —
                                   // insecure: skips host-key verification, for hosts recreated
                                   // on the same address.

    // -J host[:port][,host2[:port2]...] — hop through one or more
    // intermediate hosts to reach `host`, replacing a manual multi-hop ssh.
    // nil/empty means "connect directly", matching today's behavior.
    var proxyJump: String?

    /// Fallback used when a tunnel doesn't override `serverAliveInterval`.
    static let defaultServerAliveInterval = 30
    /// Fallback used when a tunnel doesn't override `serverAliveCountMax`.
    static let defaultServerAliveCountMax = 3

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        portMappings: [PortMapping] = [PortMapping()],
        identityFile: String? = nil,
        autoConnect: Bool = false,
        useAlias: Bool = false,
        connectTimeout: Int? = nil,
        serverAliveInterval: Int? = nil,
        serverAliveCountMax: Int? = nil,
        compression: Bool = false,
        disableTCPKeepAlive: Bool = false,
        skipHostKeyCheck: Bool = false,
        proxyJump: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.portMappings = portMappings.isEmpty ? [PortMapping()] : portMappings
        self.identityFile = identityFile
        self.autoConnect = autoConnect
        self.useAlias = useAlias
        self.connectTimeout = connectTimeout
        self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax
        self.compression = compression
        self.disableTCPKeepAlive = disableTCPKeepAlive
        self.skipHostKeyCheck = skipHostKeyCheck
        self.proxyJump = proxyJump
    }

    /// True when `other` would produce the same `ssh` invocation as `self`.
    /// Name and autoConnect are ignored — changing them needs no reconnect.
    func hasSameConnection(as other: Tunnel) -> Bool {
        host == other.host &&
        port == other.port &&
        portMappings == other.portMappings &&
        identityFile == other.identityFile &&
        useAlias == other.useAlias &&
        connectTimeout == other.connectTimeout &&
        serverAliveInterval == other.serverAliveInterval &&
        serverAliveCountMax == other.serverAliveCountMax &&
        compression == other.compression &&
        disableTCPKeepAlive == other.disableTCPKeepAlive &&
        skipHostKeyCheck == other.skipHostKeyCheck &&
        proxyJump == other.proxyJump
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, portMappings, identityFile, autoConnect, useAlias
        case connectTimeout, serverAliveInterval, serverAliveCountMax
        case compression, disableTCPKeepAlive, skipHostKeyCheck, proxyJump
        // Legacy single-mapping fields
        case localHost, localPort, remoteHost, remotePort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        autoConnect = try container.decode(Bool.self, forKey: .autoConnect)
        useAlias = try container.decodeIfPresent(Bool.self, forKey: .useAlias) ?? false
        // Absent in older configs — nil keeps the previous hardcoded behavior.
        connectTimeout = try container.decodeIfPresent(Int.self, forKey: .connectTimeout)
        serverAliveInterval = try container.decodeIfPresent(Int.self, forKey: .serverAliveInterval)
        serverAliveCountMax = try container.decodeIfPresent(Int.self, forKey: .serverAliveCountMax)
        // Absent in older configs — false matches today's behavior (neither
        // flag is currently passed to ssh at all).
        compression = try container.decodeIfPresent(Bool.self, forKey: .compression) ?? false
        disableTCPKeepAlive = try container.decodeIfPresent(Bool.self, forKey: .disableTCPKeepAlive) ?? false
        skipHostKeyCheck = try container.decodeIfPresent(Bool.self, forKey: .skipHostKeyCheck) ?? false
        // Absent in older configs — nil means "connect directly", i.e. no -J.
        proxyJump = try container.decodeIfPresent(String.self, forKey: .proxyJump)

        if let mappings = try container.decodeIfPresent([PortMapping].self, forKey: .portMappings),
           !mappings.isEmpty {
            portMappings = mappings
        } else {
            // Migrate old configs with a single port mapping
            let localHost = try container.decode(String.self, forKey: .localHost)
            let localPort = try container.decode(Int.self, forKey: .localPort)
            let remoteHost = try container.decode(String.self, forKey: .remoteHost)
            let remotePort = try container.decode(Int.self, forKey: .remotePort)
            portMappings = [PortMapping(
                localHost: localHost,
                localPort: localPort,
                remoteHost: remoteHost,
                remotePort: remotePort
            )]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(portMappings, forKey: .portMappings)
        try container.encodeIfPresent(identityFile, forKey: .identityFile)
        try container.encode(autoConnect, forKey: .autoConnect)
        try container.encode(useAlias, forKey: .useAlias)
        try container.encodeIfPresent(connectTimeout, forKey: .connectTimeout)
        try container.encodeIfPresent(serverAliveInterval, forKey: .serverAliveInterval)
        try container.encodeIfPresent(serverAliveCountMax, forKey: .serverAliveCountMax)
        try container.encode(compression, forKey: .compression)
        try container.encode(disableTCPKeepAlive, forKey: .disableTCPKeepAlive)
        try container.encode(skipHostKeyCheck, forKey: .skipHostKeyCheck)
        try container.encodeIfPresent(proxyJump, forKey: .proxyJump)
    }

    var mappingsSummary: String {
        portMappings.map { m in
            switch m.forward {
            case .dynamic: return "SOCKS :\(m.localPort)"
            case .remote: return "R :\(m.localPort) → :\(m.remotePort)"
            case .local: return ":\(m.localPort) → :\(m.remotePort)"
            }
        }.joined(separator: ", ")
    }

    var localPortsSummary: String {
        portMappings.map { ":\($0.localPort)" }.joined(separator: ", ")
    }
}


/// A standalone divider that begins a group; carries an optional name and is
/// reordered independently of tunnels.
struct GroupDivider: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String

    init(id: UUID = UUID(), title: String = "") {
        self.id = id
        self.title = title
    }
}

/// One entry in the sidebar/menu ordering: a tunnel or a group divider.
enum SidebarItem: Identifiable, Hashable {
    case tunnel(Tunnel)
    case divider(GroupDivider)

    var id: UUID {
        switch self {
        case .tunnel(let t): return t.id
        case .divider(let d): return d.id
        }
    }

    var tunnel: Tunnel? {
        if case .tunnel(let t) = self { return t }
        return nil
    }

    var divider: GroupDivider? {
        if case .divider(let d) = self { return d }
        return nil
    }
}

extension SidebarItem: Codable {
    private enum Kind: String, Codable { case tunnel, divider }
    private enum CodingKeys: String, CodingKey { case kind, tunnel, divider }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .tunnel: self = .tunnel(try c.decode(Tunnel.self, forKey: .tunnel))
        case .divider: self = .divider(try c.decode(GroupDivider.self, forKey: .divider))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tunnel(let t):
            try c.encode(Kind.tunnel, forKey: .kind)
            try c.encode(t, forKey: .tunnel)
        case .divider(let d):
            try c.encode(Kind.divider, forKey: .kind)
            try c.encode(d, forKey: .divider)
        }
    }
}

/// A contiguous run of tunnels between dividers.
/// `title` is nil for the leading run before the first divider.
struct TunnelGroup: Identifiable {
    let id: String
    let title: String?
    let tunnels: [Tunnel]
}

extension Array where Element == SidebarItem {
    /// All tunnels in order, ignoring dividers.
    var tunnels: [Tunnel] { compactMap(\.tunnel) }

    /// Split into groups: each divider begins a new group with its title;
    /// tunnels before the first divider form a leading group with a nil title.
    func grouped() -> [TunnelGroup] {
        var groups: [TunnelGroup] = []
        var currentTunnels: [Tunnel] = []
        var currentTitle: String?

        func flush() {
            guard let first = currentTunnels.first else { return }
            groups.append(TunnelGroup(id: first.id.uuidString, title: currentTitle, tunnels: currentTunnels))
        }

        for item in self {
            switch item {
            case .tunnel(let t):
                currentTunnels.append(t)
            case .divider(let d):
                flush()
                currentTunnels = []
                currentTitle = d.title
            }
        }
        flush()
        return groups
    }
}

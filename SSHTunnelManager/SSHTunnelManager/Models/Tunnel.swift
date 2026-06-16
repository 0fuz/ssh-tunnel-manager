import Foundation

struct PortMapping: Identifiable, Codable, Hashable {
    var id: UUID
    var localHost: String
    var localPort: Int
    var remoteHost: String
    var remotePort: Int

    init(
        id: UUID = UUID(),
        localHost: String = "127.0.0.1",
        localPort: Int = 8080,
        remoteHost: String = "127.0.0.1",
        remotePort: Int = 8080
    ) {
        self.id = id
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
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

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        portMappings: [PortMapping] = [PortMapping()],
        identityFile: String? = nil,
        autoConnect: Bool = false,
        useAlias: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.portMappings = portMappings.isEmpty ? [PortMapping()] : portMappings
        self.identityFile = identityFile
        self.autoConnect = autoConnect
        self.useAlias = useAlias
    }

    /// True when `other` would produce the same `ssh` invocation as `self`.
    /// Name and autoConnect are ignored — changing them needs no reconnect.
    func hasSameConnection(as other: Tunnel) -> Bool {
        host == other.host &&
        port == other.port &&
        portMappings == other.portMappings &&
        identityFile == other.identityFile &&
        useAlias == other.useAlias
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, portMappings, identityFile, autoConnect, useAlias
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
    }

    var mappingsSummary: String {
        portMappings.map { ":\($0.localPort) → :\($0.remotePort)" }.joined(separator: ", ")
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

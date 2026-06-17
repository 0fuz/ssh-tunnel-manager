import Foundation
import SwiftUI
import Darwin
import AppKit
import UserNotifications
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "SSHTunnelManager",
    category: "TunnelManager"
)

/// Plays the connect/disconnect feedback sounds, gated by a user preference.
/// Stored as a plain UserDefaults-backed flag (rather than @AppStorage) so it
/// can be read from this non-View class.
enum TunnelSound {
    static let soundsEnabledKey = "tunnelSoundsEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: soundsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundsEnabledKey) }
    }

    @MainActor
    static func playConnected() {
        guard isEnabled else { return }
        NSSound(named: "Pop")?.play()
    }

    @MainActor
    static func playDisconnected() {
        guard isEnabled else { return }
        NSSound(named: "Basso")?.play()
    }
}

/// Posts a user notification on connect/disconnect, gated by a user
/// preference. Unlike TunnelSound, these identify *which* tunnel changed
/// state, since a sound alone can't carry that information.
enum TunnelNotification {
    static let notificationsEnabledKey = "tunnelNotificationsEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: notificationsEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: notificationsEnabledKey) }
    }

    /// Requests notification permission once at launch. Safe to call
    /// repeatedly — the system only prompts the first time.
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                logger.info("Notification authorization was denied by the user")
            }
        }
    }

    static func notifyConnected(tunnelName: String) {
        guard isEnabled else { return }
        post(title: tunnelName, body: "Connected")
    }

    static func notifyDisconnected(tunnelName: String) {
        guard isEnabled else { return }
        post(title: tunnelName, body: "Disconnected — attempting to reconnect")
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // No content.sound here — TunnelSound is the separate, independently
        // toggled mechanism for audio feedback. Stacking both would mean a
        // sound plays twice if the user has both options enabled.

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to deliver notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}


/// File to store active PIDs for cleanup on crash/force quit
private let pidFileURL: URL = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let appFolder = appSupport.appendingPathComponent("SSHTunnelManager", isDirectory: true)
    try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
    return appFolder.appendingPathComponent("active_pids.txt")
}()

/// Process group ID for all SSH child processes (accessed from signal handlers, so must be global).
/// Left as a plain global rather than `nonisolated(unsafe)` so it compiles on Swift 5.9 /
/// Xcode 15.2 (which the release CI pins). It is written once at startup and read from C-level
/// signal/atexit handlers; under strict concurrency this is a benign warning, not an error.
private var sshProcessGroupID: pid_t = 0

/// Kill SSH processes for all local ports in a tunnel
private func killSSHProcessesForTunnel(_ tunnel: Tunnel) {
    for mapping in tunnel.portMappings {
        findAndKillSSHProcesses(localPort: mapping.localPort)
    }
}

/// Kill SSH processes using specified local port
private func findAndKillSSHProcesses(localPort: Int) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    task.arguments = ["-f", "ssh.*-[LD].*:\(localPort)[: ]"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
}

/// Kill processes by PIDs from file (cleanup from previous session)
private func killOrphanedProcesses() {
    guard FileManager.default.fileExists(atPath: pidFileURL.path) else { return }

    if let content = try? String(contentsOf: pidFileURL, encoding: .utf8) {
        let pids = content.components(separatedBy: "\n").compactMap { Int32($0) }
        for pid in pids {
            kill(pid, SIGKILL)
        }
    }
    try? FileManager.default.removeItem(at: pidFileURL)
}

/// Save active PIDs to file
private func savePIDsToFile(_ pids: [Int32]) {
    let content = pids.map { String($0) }.joined(separator: "\n")
    try? content.write(to: pidFileURL, atomically: true, encoding: .utf8)
}

/// Remove PID file
private func removePIDFile() {
    try? FileManager.default.removeItem(at: pidFileURL)
}

/// Kill entire process group (all SSH children)
private func killProcessGroup() {
    if sshProcessGroupID != 0 {
        // Kill entire process group with negative PID
        kill(-sshProcessGroupID, SIGKILL)
    }
}

@Observable
@MainActor
class TunnelManager {
    var items: [SidebarItem] = []
    var tunnels: [Tunnel] { items.tunnels }
    private var processIDs: [UUID: Int32] = [:]
    private var connectionStatus: [UUID: ConnectionStatus] = [:]
    private var shouldBeConnected: Set<UUID> = [] // Tracks desired state for reconnection
    private var connectingInFlight: Set<UUID> = [] // Tunnels whose SSH process is mid-startup
    private let configStore = ConfigStore()
    private var reconnectTask: Task<Void, Never>?

    init() {
        // Kill any orphaned processes from previous session
        killOrphanedProcesses()

        // Create a new process group for SSH processes
        // Using our own PID ensures children inherit this group
        sshProcessGroupID = getpid()

        // Register atexit handler as last resort cleanup
        atexit {
            killProcessGroup()
        }

        Task {
            await loadTunnels()
            autoConnectTunnels()
        }

        // Start reconnection monitor
        startReconnectMonitor()
    }

    private func startReconnectMonitor() {
        reconnectTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                reconnectDisconnectedTunnels()
            }
        }
    }

    private func reconnectDisconnectedTunnels() {
        for tunnelID in shouldBeConnected {
            guard let tunnel = tunnels.first(where: { $0.id == tunnelID }) else {
                shouldBeConnected.remove(tunnelID)
                continue
            }

            // Respawn whenever a desired-connected tunnel has no live process and
            // isn't already starting up. Keying off process liveness (rather than
            // the status label) is what makes auto-reconnect actually fire after a
            // tunnel drops — handleProcessTermination leaves the status at
            // .connecting, which the old `== .disconnected` check never matched.
            if processIDs[tunnelID] == nil && !connectingInFlight.contains(tunnelID) {
                beginConnecting(tunnel: tunnel)
            }
        }
    }

    /// Free the local ports, then launch the SSH process for a tunnel.
    /// `connectingInFlight` guards against concurrent callers (a manual connect
    /// and the reconnect monitor) racing to start two processes for one tunnel.
    private func beginConnecting(tunnel: Tunnel) {
        let id = tunnel.id
        guard !connectingInFlight.contains(id) else { return }
        connectingInFlight.insert(id)
        connectionStatus[id] = .connecting

        let tunnelCopy = tunnel

        Task.detached {
            killSSHProcessesForTunnel(tunnelCopy)
            try? await Task.sleep(for: .milliseconds(100))

            await MainActor.run {
                self.startSSHProcess(tunnel: tunnelCopy)
            }
        }
    }

    func loadTunnels() async {
        items = await configStore.load()
    }

    func saveTunnels() async {
        await configStore.save(items)
    }

    private func autoConnectTunnels() {
        for tunnel in tunnels where tunnel.autoConnect {
            connect(tunnel: tunnel)
        }
    }

    func isConnected(_ tunnel: Tunnel) -> Bool {
        connectionStatus[tunnel.id] == .connected
    }

    func status(for tunnel: Tunnel) -> ConnectionStatus {
        connectionStatus[tunnel.id] ?? .disconnected
    }

    func connect(tunnel: Tunnel) {
        guard !isConnected(tunnel) else { return }

        // Record desired state so the monitor keeps the tunnel alive, then start.
        shouldBeConnected.insert(tunnel.id)
        beginConnecting(tunnel: tunnel)
    }

    private func startSSHProcess(tunnel: Tunnel) {
        // Startup is no longer in flight, whatever the outcome below.
        connectingInFlight.remove(tunnel.id)

        // The user (or an in-place update) may have cancelled while we were
        // freeing the local port — don't resurrect a tunnel that's no longer wanted.
        guard shouldBeConnected.contains(tunnel.id) else {
            connectionStatus[tunnel.id] = .disconnected
            return
        }

        // Reject hosts that would let ssh parse the destination as an option
        // (e.g. "-oProxyCommand=…") or that are empty — otherwise the reconnect
        // monitor would respawn a doomed process every few seconds.
        let host = tunnel.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.hasPrefix("-") else {
            logger.error("Refusing to start tunnel \"\(tunnel.name, privacy: .public)\": invalid host \"\(host, privacy: .public)\"")
            shouldBeConnected.remove(tunnel.id)
            connectionStatus[tunnel.id] = .disconnected
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        // One forward flag per port mapping — -L for a local forward, -D for a
        // SOCKS proxy — all carried by a single ssh process.
        var arguments = ["-N"]
        for mapping in tunnel.portMappings {
            switch mapping.forward {
            case .local:
                arguments.append(contentsOf: [
                    "-L", "\(mapping.localHost):\(mapping.localPort):\(mapping.remoteHost):\(mapping.remotePort)"
                ])
            case .dynamic:
                arguments.append(contentsOf: [
                    "-D", "\(mapping.localHost):\(mapping.localPort)"
                ])
            }
        }

        // Connection options. In host mode always pass -p (and -i if set); in
        // alias mode let ~/.ssh/config supply them, overriding -p only for a
        // non-default port.
        if !tunnel.useAlias, let identityFile = tunnel.identityFile, !identityFile.isEmpty {
            arguments.append(contentsOf: ["-i", (identityFile as NSString).expandingTildeInPath])
        }
        if !tunnel.useAlias || tunnel.port != 22 {
            arguments.append(contentsOf: ["-p", "\(tunnel.port)"])
        }

        // Destination, then robustness/hardening options. Forcing a dedicated,
        // forward-only connection (RequestTTY / RemoteCommand / ControlMaster /
        // ControlPath) stops login-oriented alias directives from allocating a
        // TTY, running a remote shell, or piggybacking on an existing master
        // socket and making ssh exit early — which the monitor would see as a
        // drop and respawn, causing the tunnel to flap.
        arguments.append(host)
        arguments.append(contentsOf: [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=\(tunnel.serverAliveInterval ?? Tunnel.defaultServerAliveInterval)",
            "-o", "ServerAliveCountMax=\(tunnel.serverAliveCountMax ?? Tunnel.defaultServerAliveCountMax)",
            "-o", "RequestTTY=no",
            "-o", "RemoteCommand=none",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none"
        ])
        if let connectTimeout = tunnel.connectTimeout {
            arguments.append(contentsOf: ["-o", "ConnectTimeout=\(connectTimeout)"])
        }

        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let pid = process.processIdentifier
            processIDs[tunnel.id] = pid
            connectionStatus[tunnel.id] = .connected
            TunnelSound.playConnected()
            TunnelNotification.notifyConnected(tunnelName: tunnel.name)

            // Save PIDs to file for crash recovery
            updatePIDFile()

            let tunnelID = tunnel.id
            Task.detached { [weak self] in
                process.waitUntilExit()
                await MainActor.run { [weak self] in
                    self?.handleProcessTermination(tunnelID: tunnelID)
                }
            }
        } catch {
            logger.error("Failed to start SSH tunnel \"\(tunnel.name, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            connectionStatus[tunnel.id] = .disconnected
        }
    }

    private func updatePIDFile() {
        let pids = Array(processIDs.values)
        if pids.isEmpty {
            removePIDFile()
        } else {
            savePIDsToFile(pids)
        }
    }

    private func handleProcessTermination(tunnelID: UUID) {
        processIDs.removeValue(forKey: tunnelID)
        let tunnelName = tunnels.first(where: { $0.id == tunnelID })?.name ?? "Tunnel"
        // If should still be connected, mark as connecting (will trigger reconnect)
        // Otherwise mark as disconnected
        if shouldBeConnected.contains(tunnelID) {
            connectionStatus[tunnelID] = .connecting
        } else {
            connectionStatus[tunnelID] = .disconnected
        }
        TunnelSound.playDisconnected()
        TunnelNotification.notifyDisconnected(tunnelName: tunnelName)
        updatePIDFile()
    }

    func disconnect(tunnel: Tunnel) {
        // Remove from auto-reconnect set and cancel any in-flight startup
        shouldBeConnected.remove(tunnel.id)
        connectingInFlight.remove(tunnel.id)

        guard let pid = processIDs[tunnel.id] else {
            connectionStatus[tunnel.id] = .disconnected
            return
        }

        // Send SIGTERM first, then SIGKILL after brief delay
        kill(pid, SIGTERM)

        // Give process time to terminate gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            kill(pid, SIGKILL) // Force kill if still alive
        }

        processIDs.removeValue(forKey: tunnel.id)
        connectionStatus[tunnel.id] = .disconnected
        updatePIDFile()
    }

    func toggle(tunnel: Tunnel) {
        // Key off desired state so a tunnel that's connecting/reconnecting can be
        // cancelled — isConnected alone (only .connected) would re-trigger connect
        // even though the UI already shows .connecting as "on".
        if shouldBeConnected.contains(tunnel.id) || isConnected(tunnel) {
            disconnect(tunnel: tunnel)
        } else {
            connect(tunnel: tunnel)
        }
    }

    // MARK: - Groups

    /// A group counts as "on" only when every tunnel in it is connected or
    /// desired-connected — so a half-on group reads as off and one tap fills it in.
    func isGroupActive(_ groupTunnels: [Tunnel]) -> Bool {
        guard !groupTunnels.isEmpty else { return false }
        return groupTunnels.allSatisfy { shouldBeConnected.contains($0.id) || isConnected($0) }
    }

    /// Connect every tunnel in the group, or disconnect them all if already on.
    func toggleGroup(_ groupTunnels: [Tunnel]) {
        if isGroupActive(groupTunnels) {
            for tunnel in groupTunnels { disconnect(tunnel: tunnel) }
        } else {
            for tunnel in groupTunnels { connect(tunnel: tunnel) }
        }
    }

    // MARK: - Dividers

    /// Insert a standalone divider after the given tunnel (or at the top when
    /// nothing is selected). It can then be dragged anywhere in the list.
    /// Returns the new divider so the caller can prompt for a name.
    @discardableResult
    func addDivider(after tunnelID: UUID?) -> GroupDivider {
        let divider = GroupDivider()
        let item = SidebarItem.divider(divider)
        if let id = tunnelID, let index = items.firstIndex(where: { $0.id == id }) {
            items.insert(item, at: index + 1)
        } else {
            items.insert(item, at: 0)
        }
        Task { await saveTunnels() }
        return divider
    }

    func renameDivider(_ id: UUID, title: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .divider(var divider) = items[index] else { return }
        divider.title = title
        items[index] = .divider(divider)
        Task { await saveTunnels() }
    }

    func deleteDivider(_ id: UUID) {
        items.removeAll { $0.divider?.id == id }
        Task { await saveTunnels() }
    }

    // MARK: - Tunnel CRUD

    func addTunnel() {
        let newTunnel = Tunnel(
            name: "New Tunnel",
            host: "user@example.com",
            port: 22
        )
        items.append(.tunnel(newTunnel))
        Task { await saveTunnels() }
    }

    func deleteTunnel(_ tunnel: Tunnel) {
        if isConnected(tunnel) {
            disconnect(tunnel: tunnel)
        }
        items.removeAll { $0.tunnel?.id == tunnel.id }
        Task { await saveTunnels() }
    }

    func updateTunnel(_ tunnel: Tunnel) {
        guard let index = items.firstIndex(where: { $0.tunnel?.id == tunnel.id }),
              let existing = items[index].tunnel else { return }

        // Restart an active tunnel so new settings take effect (the old code
        // disconnected but never reconnected). Skip the restart when only
        // cosmetic fields like the name changed, to avoid needless flapping —
        // the detail view auto-saves on every focus change.
        let wasActive = shouldBeConnected.contains(tunnel.id) || processIDs[tunnel.id] != nil
        let needsRestart = wasActive && !existing.hasSameConnection(as: tunnel)
        if needsRestart {
            disconnect(tunnel: existing)
        }
        items[index] = .tunnel(tunnel)
        Task { await saveTunnels() }
        if needsRestart {
            connect(tunnel: tunnel)
        }
    }

    /// Reorder sidebar items (tunnels and dividers) — used by drag-and-drop.
    func moveItems(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        Task { await saveTunnels() }
    }

    func canMoveUp(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        return index > 0
    }

    func canMoveDown(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        return index < items.count - 1
    }

    func moveItemUp(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index > 0 else { return }
        items.swapAt(index, index - 1)
        Task { await saveTunnels() }
    }

    func moveItemDown(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index < items.count - 1 else { return }
        items.swapAt(index, index + 1)
        Task { await saveTunnels() }
    }

    func cloneTunnel(_ tunnel: Tunnel) -> Tunnel {
        var clone = tunnel
        clone.id = UUID()
        clone.name = "\(tunnel.name) (Copy)"
        if let index = items.firstIndex(where: { $0.tunnel?.id == tunnel.id }) {
            items.insert(.tunnel(clone), at: index + 1)
        } else {
            items.append(.tunnel(clone))
        }
        Task { await saveTunnels() }
        return clone
    }

    /// Disconnect all tunnels - called on app termination
    func disconnectAll() {
        // Stop reconnection monitor
        reconnectTask?.cancel()
        reconnectTask = nil
        shouldBeConnected.removeAll()
        connectingInFlight.removeAll()

        let pids = Array(processIDs.values)

        // Kill all tracked processes immediately with SIGKILL
        for pid in pids {
            kill(pid, SIGKILL)
        }

        // Also kill by local port pattern as backup (catches any missed processes)
        for tunnel in tunnels {
            killSSHProcessesForTunnel(tunnel)
        }

        processIDs.removeAll()
        for tunnel in tunnels {
            connectionStatus[tunnel.id] = .disconnected
        }

        // Clean up PID file
        removePIDFile()
    }

    /// Synchronous disconnect for use in signal handlers (non-async context)
    nonisolated func disconnectAllSync() {
        // Read PIDs file directly since we can't access actor state
        if let content = try? String(contentsOf: pidFileURL, encoding: .utf8) {
            let pids = content.components(separatedBy: "\n").compactMap { Int32($0) }
            for pid in pids {
                kill(pid, SIGKILL)
            }
        }
        // Kill process group as ultimate fallback
        killProcessGroup()
        removePIDFile()
    }

}

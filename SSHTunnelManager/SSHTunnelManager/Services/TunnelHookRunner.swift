import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "SSHTunnelManager",
    category: "TunnelHook"
)

/// Runs the user-defined shell commands attached to a tunnel's connect/disconnect
/// events. Commands run via `/bin/sh -c` so pipes, `&&`, and multi-line scripts
/// work, with tunnel context injected as environment variables ($LOCAL_PORT,
/// $HOST, $TUNNEL_NAME, …). Fire-and-forget: success is silent, a non-zero exit
/// (or a launch failure) is surfaced via a notification and os_log.
enum TunnelHookRunner {
    /// Launch `command` for `tunnel`'s `event` ("connect"/"disconnect"). A blank
    /// command is a no-op. Runs off the main thread; never blocks the caller.
    static func run(command: String, tunnel: Tunnel, event: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Inherit the app's environment so PATH (and the user's session) survive —
        // `open`, Homebrew tools, etc. rely on it. A bare dict would wipe PATH.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in tunnel.hookEnvironment { environment[key] = value }

        let tunnelName = tunnel.name

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", trimmed]
            process.environment = environment

            // Merge stdout+stderr into one pipe so the failure log carries whatever
            // the command emitted. readDataToEndOfFile doubles as the exit wait.
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let exitCode = process.terminationStatus
                if exitCode != 0 {
                    let output = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.error("""
                        \(event, privacy: .public) hook for "\(tunnelName, privacy: .public)" \
                        exited \(exitCode): \(output, privacy: .public)
                        """)
                    TunnelNotification.notifyHookFailed(tunnelName: tunnelName, event: event)
                }
            } catch {
                logger.error("""
                    Failed to launch \(event, privacy: .public) hook for \
                    "\(tunnelName, privacy: .public)": \(error.localizedDescription, privacy: .public)
                    """)
                TunnelNotification.notifyHookFailed(tunnelName: tunnelName, event: event)
            }
        }
    }
}

import SwiftUI
import Darwin

@main
struct SSHTunnelManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu Bar
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.tunnelManager)
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
        .menuBarExtraStyle(.window)

        // Main Settings Window
        Window("SSH Tunnel Manager", id: "main") {
            ContentView()
                .environment(appDelegate.tunnelManager)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .defaultSize(width: 800, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tunnel") {
                    appDelegate.tunnelManager.addTunnel()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let tunnelManager = TunnelManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make app accessory - no dock icon, proper focus handling
        NSApp.setActivationPolicy(.accessory)
        // Disable Sudden Termination - ensures cleanup handlers run
        ProcessInfo.processInfo.disableSuddenTermination()

        // Ask for notification permission up front. This is a no-op prompt
        // if the user never enables "Show Notifications" in settings, and
        // the system only asks once regardless of how often this is called.
        TunnelNotification.requestAuthorizationIfNeeded()

        // Register for additional termination signals
        setupSignalHandlers()

        // Register for workspace notifications (logout, shutdown, restart)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        // Observe window closing to return focus to previous app
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func handleWindowClose(_ notification: Notification) {
        // When Settings window closes, hide app to return focus to previous app
        // Small delay to ensure window is fully closed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Only hide if no windows are visible
            if NSApp.windows.filter({ $0.isVisible && $0.className != "NSStatusBarWindow" }).isEmpty {
                NSApp.hide(nil)
            }
        }
    }

    @objc private func workspaceWillPowerOff(_ notification: Notification) {
        tunnelManager.disconnectAll()
    }

    private func setupSignalHandlers() {
        // Handle common termination signals
        let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

        for sig in signals {
            signal(sig) { _ in
                // Signal handlers must be synchronous and non-blocking
                // Use the sync version that reads PIDs from file
                if let delegate = NSApplication.shared.delegate as? AppDelegate {
                    delegate.tunnelManager.disconnectAllSync()
                }
                exit(0)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tunnelManager.disconnectAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cleanup before termination is confirmed
        tunnelManager.disconnectAll()
        return .terminateNow
    }
}

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "SSHTunnelManager",
    category: "ConfigStore"
)

actor ConfigStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("SSHTunnelManager", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

        self.fileURL = appFolder.appendingPathComponent("tunnels.json")
    }

    func load() -> [SidebarItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            // Current format: an array of sidebar items (tunnels + dividers).
            if let items = try? JSONDecoder().decode([SidebarItem].self, from: data) {
                return items
            }
            // Legacy format: a bare array of tunnels — wrap each as an item.
            let tunnels = try JSONDecoder().decode([Tunnel].self, from: data)
            return tunnels.map { .tunnel($0) }
        } catch {
            logger.error("Failed to load tunnels: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func save(_ items: [SidebarItem]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save tunnels: \(error.localizedDescription, privacy: .public)")
        }
    }
}

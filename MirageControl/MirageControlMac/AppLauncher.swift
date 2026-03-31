//
//  AppLauncher.swift
//  MirageControlMac
//

import AppKit
import Foundation

@MainActor
final class AppLauncher {
    static let shared = AppLauncher()
    private init() {}

    func launch(bundleID: String) async {
        // First check if already running — bring to front
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            running.activate(options: .activateIgnoringOtherApps)
            return
        }
        // Find app URL and open it
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            // Silently ignore errors — app may already be launching
        }
    }
}

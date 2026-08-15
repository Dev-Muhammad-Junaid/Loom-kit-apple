//
//  ActiveAppMonitor.swift
//  DeckHandMac
//
//

import AppKit
import Combine
import Foundation
import LoomKit

@MainActor
final class ActiveAppMonitor {
    static let shared = ActiveAppMonitor()

    private var cancellables = Set<AnyCancellable>()
    private var activeConnections: [UUID: LoomConnectionHandle] = [:]

    private init() {
        // Observe app activations
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let name = app.localizedName {
                    Task {
                        await self?.broadcastActiveApp(name: name, bundleID: app.bundleIdentifier)
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Register a new connection to receive active app updates.
    /// Also sends the current active app immediately upon connection.
    func addConnection(_ handle: LoomConnectionHandle, id: UUID) {
        activeConnections[id] = handle

        // Send current frontmost app immediately
        if let currentApp = NSWorkspace.shared.frontmostApplication,
           let name = currentApp.localizedName {
            Task {
                try? await handle.send(.activeAppUpdate(name: name, bundleID: currentApp.bundleIdentifier))
            }
        }
    }

    func removeConnection(id: UUID) {
        activeConnections.removeValue(forKey: id)
    }

    private func broadcastActiveApp(name: String, bundleID: String?) async {
        let msg = ControlMessage.activeAppUpdate(name: name, bundleID: bundleID)
        for handle in activeConnections.values {
            try? await handle.send(msg)
        }
    }
}

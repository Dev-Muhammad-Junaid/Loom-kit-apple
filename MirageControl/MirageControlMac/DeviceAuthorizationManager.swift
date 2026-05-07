//
//  DeviceAuthorizationManager.swift
//  MirageControlMac
//

import Foundation
import UserNotifications
import Loom
import LoomKit
import SwiftUI
import Combine

@MainActor
final class DeviceAuthorizationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = DeviceAuthorizationManager()

    @AppStorage("authorizedDeviceIDs") private var authorizedDeviceIDsData: Data = Data()
    
    @Published var authorizedDeviceIDs: Set<LoomPeerID> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(authorizedDeviceIDs) {
                authorizedDeviceIDsData = data
            }
        }
    }
    
    @Published var pendingConnections: [LoomConnectionSnapshot] = []
    
    // Retain handles so we can route them after approval
    private var pendingHandles: [UUID: LoomConnectionHandle] = [:]
    private var pendingRequestedAt: [UUID: Date] = [:]
    private var pendingExpiryTasks: [UUID: Task<Void, Never>] = [:]

    // Callback so MacMenuBarView can pass authorized handles to the receiver
    var onDeviceAuthorized: ((LoomConnectionHandle) -> Void)?
    private static let pendingRequestTimeout: Duration = .seconds(45)

    override init() {
        super.init()
        if let decoded = try? JSONDecoder().decode(Set<LoomPeerID>.self, from: authorizedDeviceIDsData) {
            authorizedDeviceIDs = decoded
        }
    }
    
    func requestNotificationPermissions() {
        UNUserNotificationCenter.current().delegate = self
        
        // Define Notification Categories / Actions first to prevent XPC races
        let acceptAction = UNNotificationAction(identifier: "ACCEPT_ACTION", title: "Allow", options: .foreground)
        let rejectAction = UNNotificationAction(identifier: "REJECT_ACTION", title: "Deny", options: .destructive)
        let category = UNNotificationCategory(identifier: "INCOMING_CONNECTION", actions: [acceptAction, rejectAction], intentIdentifiers: [], options: [])
        
        UNUserNotificationCenter.current().setNotificationCategories([category])

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable success, error in
            if let error = error {
                MirageLog.trust.error("Notification auth error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func isAuthorized(peerID: LoomPeerID) -> Bool {
        return authorizedDeviceIDs.contains(peerID)
    }

    func handleIncomingConnection(_ connection: LoomConnectionSnapshot, handle: LoomConnectionHandle) {
        if isAuthorized(peerID: connection.peerID) {
            Task {
                try? await handle.send(.authorizationStatus(status: "granted"))
            }
            onDeviceAuthorized?(handle)
            return
        }

        if let existing = pendingConnections.first(where: { $0.peerID == connection.peerID && $0.id != connection.id }) {
            removePendingConnection(id: existing.id)
            if let oldHandle = pendingHandles.removeValue(forKey: existing.id) {
                Task {
                    try? await oldHandle.send(.authorizationStatus(status: "denied"))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await oldHandle.disconnect()
                }
            }
        }
        
        // Not authorized, add to pending list
        if !pendingConnections.contains(where: { $0.id == connection.id }) {
            pendingConnections.append(connection)
            pendingHandles[connection.id] = handle
            pendingRequestedAt[connection.id] = Date()
            Task {
                try? await handle.send(.authorizationStatus(status: "pending"))
            }
            showNotification(for: connection)
            schedulePendingExpiry(for: connection.id)
        }
    }
    
    func authorize(connection: LoomConnectionSnapshot) {
        authorizedDeviceIDs.insert(connection.peerID)
        let peerPending = pendingConnections
            .filter { $0.peerID == connection.peerID }
            .sorted { $0.connectedAt > $1.connectedAt }
        let target = peerPending.first ?? connection
        let staleForPeer = peerPending.filter { $0.id != target.id }

        for stale in staleForPeer {
            removePendingConnection(id: stale.id)
            if let staleHandle = pendingHandles.removeValue(forKey: stale.id) {
                Task {
                    try? await staleHandle.send(.authorizationStatus(status: "denied"))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await staleHandle.disconnect()
                }
            }
        }

        removePendingConnection(id: target.id)
        if let handle = pendingHandles.removeValue(forKey: target.id) {
            Task {
                try? await handle.send(.authorizationStatus(status: "granted"))
                onDeviceAuthorized?(handle)
            }
        }
    }
    
    func reject(connection: LoomConnectionSnapshot, loomContext: LoomContext) {
        removePendingConnection(id: connection.id)
        if let handle = pendingHandles.removeValue(forKey: connection.id) {
            Task {
                try? await handle.send(.authorizationStatus(status: "denied"))
                try? await Task.sleep(nanoseconds: 100_000_000) // allow packet to send
                await loomContext.disconnect(connection)
            }
        }
    }
    
    func removeAndDisconnect(connection: LoomConnectionSnapshot, loomContext: LoomContext) {
        authorizedDeviceIDs.remove(connection.peerID)
        removePendingConnection(id: connection.id)
        Task {
            await loomContext.disconnect(connection)
        }
    }

    func handleDismissal(_ dismissal: LoomConnectionDismissal) {
        removePendingConnection(id: dismissal.id)
        pendingHandles.removeValue(forKey: dismissal.id)
    }

    func pendingRequestedDate(for connectionID: UUID) -> Date? {
        pendingRequestedAt[connectionID]
    }

    func fallbackPrunePendingWithoutActiveConnection(activeConnectionIDs: Set<UUID>) {
        let orphaned = pendingConnections
            .map(\.id)
            .filter { !activeConnectionIDs.contains($0) }
        for id in orphaned {
            removePendingConnection(id: id)
            pendingHandles.removeValue(forKey: id)
        }
    }

    private func showNotification(for connection: LoomConnectionSnapshot) {
        let content = UNMutableNotificationContent()
        content.title = "MirageControl Connection"
        content.body = "Incoming control request from \(connection.peerName). Allow access?"
        content.sound = .default
        content.categoryIdentifier = "INCOMING_CONNECTION"
        
        // Stash both connection and peer IDs so notification actions can
        // still resolve to the latest pending request for this peer.
        content.userInfo = [
            "connectionID": connection.id.uuidString,
            "peerID": connection.peerID.uuidString,
        ]
        
        let request = UNNotificationRequest(identifier: "conn-\(connection.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func schedulePendingExpiry(for connectionID: UUID) {
        pendingExpiryTasks[connectionID]?.cancel()
        pendingExpiryTasks[connectionID] = Task { [weak self] in
            try? await Task.sleep(for: Self.pendingRequestTimeout)
            await MainActor.run {
                guard let self else { return }
                guard self.pendingConnections.contains(where: { $0.id == connectionID }) else { return }
                self.removePendingConnection(id: connectionID)
                if let handle = self.pendingHandles.removeValue(forKey: connectionID) {
                    Task {
                        try? await handle.send(.authorizationStatus(status: "denied"))
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        await handle.disconnect()
                    }
                }
            }
        }
    }

    private func removePendingConnection(id: UUID) {
        pendingConnections.removeAll(where: { $0.id == id })
        pendingRequestedAt.removeValue(forKey: id)
        pendingExpiryTasks[id]?.cancel()
        pendingExpiryTasks.removeValue(forKey: id)
        let notificationID = "conn-\(id.uuidString)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    // MARK: - UNUserNotificationCenterDelegate
    
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let idString = response.notification.request.content.userInfo["connectionID"] as? String
        let peerIDString = response.notification.request.content.userInfo["peerID"] as? String
        
        Task { @MainActor in
            if let idString = idString, let connectionID = UUID(uuidString: idString) {
                // Find the pending connection; if the notification is stale
                // for an older connection ID, fall back to the latest pending
                // request from the same peer.
                let pending =
                    self.pendingConnections.first(where: { $0.id == connectionID })
                    ?? {
                        guard let peerIDString, let peerUUID = UUID(uuidString: peerIDString) else {
                            return nil
                        }
                        let peerID = LoomPeerID(deviceID: peerUUID)
                        return self.pendingConnections.last(where: { $0.peerID == peerID })
                    }()
                if let pending {
                    if actionIdentifier == "ACCEPT_ACTION" {
                        self.authorize(connection: pending)
                    } else if actionIdentifier == "REJECT_ACTION" {
                        self.removePendingConnection(id: connectionID)
                        if let handle = self.pendingHandles.removeValue(forKey: connectionID) {
                            Task {
                                try? await handle.send(.authorizationStatus(status: "denied"))
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                await handle.disconnect()
                            }
                        }
                    }
                }
            }
        }
        completionHandler()
    }
}

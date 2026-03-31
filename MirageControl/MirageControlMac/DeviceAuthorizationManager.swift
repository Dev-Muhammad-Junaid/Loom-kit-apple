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

    // Callback so MacMenuBarView can pass authorized handles to the receiver
    var onDeviceAuthorized: ((LoomConnectionHandle) -> Void)?

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
                print("MirageControl: Notification auth error: \(error.localizedDescription)")
            }
        }
    }

    func isAuthorized(peerID: LoomPeerID) -> Bool {
        return authorizedDeviceIDs.contains(peerID)
    }

    func handleIncomingConnection(_ connection: LoomConnectionSnapshot, handle: LoomConnectionHandle) {
        if isAuthorized(peerID: connection.peerID) {
            Task {
                try? await handle.send(ControlMessage.authorizationStatus(status: "granted"))
            }
            onDeviceAuthorized?(handle)
            return
        }
        
        // Not authorized, add to pending list
        if !pendingConnections.contains(where: { $0.id == connection.id }) {
            pendingConnections.append(connection)
            pendingHandles[connection.id] = handle
            Task {
                try? await handle.send(ControlMessage.authorizationStatus(status: "pending"))
            }
            showNotification(for: connection)
        }
    }
    
    func authorize(connection: LoomConnectionSnapshot) {
        authorizedDeviceIDs.insert(connection.peerID)
        pendingConnections.removeAll(where: { $0.id == connection.id })
        if let handle = pendingHandles.removeValue(forKey: connection.id) {
            Task {
                try? await handle.send(ControlMessage.authorizationStatus(status: "granted"))
                onDeviceAuthorized?(handle)
            }
        }
    }
    
    func reject(connection: LoomConnectionSnapshot, loomContext: LoomContext) {
        pendingConnections.removeAll(where: { $0.id == connection.id })
        if let handle = pendingHandles.removeValue(forKey: connection.id) {
            Task {
                try? await handle.send(ControlMessage.authorizationStatus(status: "denied"))
                try? await Task.sleep(nanoseconds: 100_000_000) // allow packet to send
                await loomContext.disconnect(connection)
            }
        }
    }
    
    func removeAndDisconnect(connection: LoomConnectionSnapshot, loomContext: LoomContext) {
        authorizedDeviceIDs.remove(connection.peerID)
        Task {
            await loomContext.disconnect(connection)
        }
    }

    private func showNotification(for connection: LoomConnectionSnapshot) {
        let content = UNMutableNotificationContent()
        content.title = "MirageControl Connection"
        content.body = "Incoming control request from \(connection.peerName). Allow access?"
        content.sound = .default
        content.categoryIdentifier = "INCOMING_CONNECTION"
        
        // Stash the connection ID into the notification so we know who to approve
        content.userInfo = ["connectionID": connection.id.uuidString]
        
        let request = UNNotificationRequest(identifier: "conn-\(connection.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate
    
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let idString = response.notification.request.content.userInfo["connectionID"] as? String
        
        Task { @MainActor in
            if let idString = idString, let connectionID = UUID(uuidString: idString) {
                // Find the pending connection
                if let pending = self.pendingConnections.first(where: { $0.id == connectionID }) {
                    if actionIdentifier == "ACCEPT_ACTION" {
                        self.authorize(connection: pending)
                    } else if actionIdentifier == "REJECT_ACTION" {
                        self.pendingConnections.removeAll(where: { $0.id == connectionID })
                        self.pendingHandles.removeValue(forKey: connectionID)
                    }
                }
            }
        }
        completionHandler()
    }
}

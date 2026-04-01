//
//  MacHostApp.swift
//  MirageControlMac
//

import LoomKit
import SwiftUI

@MainActor
final class MacDaemon: ObservableObject {
    let container: LoomContainer
    let receiver = ControlReceiver()

    init() {
        container = try! LoomContainer(
            for: LoomContainerConfiguration(
                serviceType: "_miragecontrol._tcp",
                serviceName: Host.current().localizedName ?? "Mac",
                deviceIDSuiteName: "MirageControlLoomStore"
            )
        )
        
        let context = container.mainContext
        
        // Wire up authorization manager to feed ControlReceiver
        DeviceAuthorizationManager.shared.onDeviceAuthorized = { [weak receiver] handle in
            receiver?.observeConnection(handle)
        }
        
        Task {
            // Defer notification request until NSApplication is fully launched
            DeviceAuthorizationManager.shared.requestNotificationPermissions()
            
            // Proactively prompt for Screen Recording permission at launch
            // so macOS shows the dialog immediately, before the user taps screenshot.
            receiver.requestScreenCaptureIfNeeded()
            
            // Start Loom runtime permanently
            do {
                print("MirageControl: 🚀 Attempting to start LoomContext...")
                try await context.start()
                print("MirageControl: ✅ LoomContext started successfully!")
            } catch {
                print("MirageControl: ❌ FATAL ERROR starting LoomContext: \(error)")
                print("Error Description: \(error.localizedDescription)")
            }
            
            // Observe incoming iOS peer connections
            for await handle in context.incomingConnections {
                let id = await handle.id
                print("MirageControl: 📥 Received incoming connection: \(id)")
                
                // allow a micro-delay for context store sync
                try? await Task.sleep(nanoseconds: 100_000_000)
                
                if let snapshot = await MainActor.run(body: { context.connections.first(where: { $0.id == id }) }) {
                    await DeviceAuthorizationManager.shared.handleIncomingConnection(snapshot, handle: handle)
                }
            }
        }
    }
}

@main
struct MacHostApp: App {
    @StateObject private var daemon = MacDaemon()

    var body: some Scene {
        MenuBarExtra("MirageControl", systemImage: "cursorarrow.rays") {
            MacMenuBarView(receiver: daemon.receiver)
                .loomContainer(daemon.container, autostart: false)
                .environmentObject(DeviceAuthorizationManager.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

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
        Task {
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
            for await connection in context.incomingConnections {
                print("MirageControl: 📥 Received incoming connection: \(await connection.id)")
                receiver.observeConnection(connection)
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
        }
        .menuBarExtraStyle(.window)
    }
}

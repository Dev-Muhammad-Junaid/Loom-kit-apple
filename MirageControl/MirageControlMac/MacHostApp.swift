//
//  MacHostApp.swift
//  MirageControlMac
//

import LoomKit
import SystemConfiguration
import SwiftUI

@MainActor
final class MacDaemon: ObservableObject {
    let container: LoomContainer?
    let receiver = ControlReceiver()

    /// Populated when `LoomContainer` construction fails so the menu-bar UI can
    /// show a real error instead of the app silently crashing on `try!`.
    @Published var fatalStartupError: String?

    /// Friendly computer name (e.g. "Junaid's MacBook Pro") using the modern
    /// `SCDynamicStore` APIs. `Host.current().localizedName` is deprecated and
    /// slated for removal from Foundation — avoid it on macOS 14+/26.
    private static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            return name
        }
        return ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
    }

    init() {
        let built: LoomContainer?
        do {
            built = try LoomContainer(
                for: LoomContainerConfiguration(
                    serviceType: "_miragecontrol._tcp",
                    serviceName: Self.computerName(),
                    deviceIDSuiteName: "MirageControlLoomStore"
                )
            )
        } catch {
            print("MirageControl: ❌ LoomContainer init failed: \(error)")
            built = nil
            fatalStartupError = error.localizedDescription
        }
        self.container = built

        guard let container = built else { return }
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

        Task {
            for await dismissal in context.dismissedConnections {
                await MainActor.run {
                    DeviceAuthorizationManager.shared.handleDismissal(dismissal)
                }
            }
        }

        Task {
            while true {
                try? await Task.sleep(for: .seconds(5))
                let activeIDs = await MainActor.run {
                    Set(context.connections.map(\.id))
                }
                await MainActor.run {
                    DeviceAuthorizationManager.shared
                        .fallbackPrunePendingWithoutActiveConnection(activeConnectionIDs: activeIDs)
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
            if let container = daemon.container {
                MacMenuBarView(receiver: daemon.receiver)
                    .loomContainer(container, autostart: false)
                    .environmentObject(DeviceAuthorizationManager.shared)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MirageControl failed to start")
                        .font(.headline)
                    Text(daemon.fatalStartupError ?? "Unknown error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(width: 280)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

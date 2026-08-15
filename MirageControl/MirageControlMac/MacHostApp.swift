//
//  MacHostApp.swift
//  MirageControlMac
//

import Loom
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
                    deviceIDSuiteName: "MirageControlLoomStore",
                    // Same-iCloud awareness: publishes this Mac's identity
                    // to the user's private CloudKit DB and merges the
                    // user's other devices into the peer view, so incoming
                    // connections from the user's own devices carry the
                    // `.cloudKitOwn` source (see MirageCloud).
                    cloudKit: MirageCloud.cloudKitConfiguration,
                    // Over-the-internet reachability: plumbed through, but
                    // inert until a relay is deployed (returns nil today).
                    remoteSignaling: MirageCloud.remoteSignalingConfiguration,
                    // No transport-level auto-retry: connection lifecycle is
                    // owned entirely by the app (explicit connect, ping/pong
                    // liveness). Retry created overlapping reconnect state
                    // machines (.stale/.reconnecting zombies) that fought
                    // the manual flow.
                    retryPolicy: .disabled
                )
            )
        } catch {
            MirageLog.app.fault("LoomContainer init failed: \(error.localizedDescription, privacy: .public)")
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
        DeviceAuthorizationManager.shared.onConnectionRevoked = { [weak receiver] connectionID in
            receiver?.cancelConsumption(connectionID: connectionID)
        }
        
        Task {
            // Defer notification request until NSApplication is fully launched
            DeviceAuthorizationManager.shared.requestNotificationPermissions()
            
            // Proactively prompt for Screen Recording permission at launch
            // so macOS shows the dialog immediately, before the user taps screenshot.
            receiver.requestScreenCaptureIfNeeded()
            
            // Start Loom runtime permanently
            do {
                MirageLog.app.info("Starting LoomContext")
                try await context.start()
                MirageLog.app.info("LoomContext started")

                // Publish signaling-backed remote reachability when a relay
                // is configured, so the user's devices can join from outside
                // the local network. Session ID is derived from the device
                // ID: stable across launches, no coordination needed.
                if MirageCloud.remoteSignalingConfiguration != nil {
                    do {
                        let deviceID = LoomSharedDeviceID.getOrCreate(suiteName: "MirageControlLoomStore")
                        let sessionID = "miragecontrol-\(deviceID.uuidString)"
                        try await context.publishRemoteReachability(sessionID: sessionID)
                        MirageLog.app.info("Published remote reachability")
                    } catch {
                        // Remote joins unavailable; local operation unaffected.
                        MirageLog.app.error("Remote reachability publish failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } catch {
                MirageLog.app.fault("LoomContext start failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.fatalStartupError = error.localizedDescription
                }
            }
            
            // Observe incoming iOS peer connections.
            //
            // We don't poll `context.connections` for the snapshot anymore —
            // the handle itself carries everything we need (`id`, `peer.id`,
            // `peer.name`). Synthesizing a snapshot from those fields removes
            // a fragile 100 ms sleep that was racing against Loom's internal
            // store sync. If LoomKit ever stops emitting the matching
            // `LoomConnectionSnapshot` synchronously, the auth flow now
            // doesn't notice — pending requests are still tracked by the
            // handle ID and resolved through `pendingHandles`.
            for await handle in context.incomingConnections {
                let id = handle.id
                let peer = handle.peer
                MirageLog.connection.info("Incoming connection \(id, privacy: .public) from \(peer.name, privacy: .public)")

                let snapshot = LoomConnectionSnapshot(
                    id: id,
                    peerID: peer.id,
                    peerName: peer.name,
                    state: .connected,
                    transportKind: .tcp,
                    connectedAt: Date(),
                    lastError: nil
                )

                DeviceAuthorizationManager.shared.handleIncomingConnection(snapshot, handle: handle)
            }
            // This loop should live as long as the process. If it ever
            // exits, the host silently stops answering connection requests
            // while still advertising on Bonjour — iPads would wait on
            // "pending" forever. Make that state loud in the logs.
            MirageLog.connection.fault("incomingConnections stream ended — host will no longer accept new connections")
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
    // The menu-bar item is created and owned by MirageAppDelegate via
    // NSStatusItem rather than SwiftUI's MenuBarExtra, so the item's
    // behavior, visibility, and panel sizing stay under our control.
    @NSApplicationDelegateAdaptor(MirageAppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible scene. A Settings scene keeps this a valid SwiftUI App
        // without opening a window; the UI lives in the status-item popover.
        Settings {
            EmptyView()
        }
    }
}

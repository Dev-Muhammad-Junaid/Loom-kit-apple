//
//  ContentRootView.swift
//  MirageControliOS
//

import LoomKit
import SwiftUI

struct ContentRootView: View {
    @Environment(\.loomContext) private var loomContext
    @State private var activeConnection: (handle: LoomConnectionHandle, peerName: String)?
    @State private var authStatus: String = "pending"

    var body: some View {
        Group {
            if let connection = activeConnection {
                ZStack {
                    ControlView(
                        connection: connection.handle,
                        peerName: connection.peerName,
                        onAuthStatusChanged: { status in
                            withAnimation(.easeInOut(duration: 0.22)) {
                                authStatus = status
                            }
                        },
                        onDisconnect: {
                            Task { await connection.handle.disconnect() }
                            activeConnection = nil
                            authStatus = "pending"
                        }
                    )
                    .opacity(authStatus == "granted" ? 1 : 0.38)
                    .disabled(authStatus != "granted")

                    if authStatus != "granted" {
                        AuthorizationOverlay(
                            status: authStatus,
                            peerName: connection.peerName
                        ) {
                            Task { await connection.handle.disconnect() }
                            activeConnection = nil
                            authStatus = "pending"
                        }
                        .transition(.opacity)
                    }
                }
                .transition(.opacity)
                .task(id: connection.peerName) {
                    authStatus = "pending"

                    // Only listen for connection-level events (disconnect) here.
                    // All message-level handling is consolidated in ControlView
                    // to avoid competing async consumers on the same stream.
                    for await event in connection.handle.events {
                        if case .disconnected = event {
                            await MainActor.run {
                                if authStatus != "denied" {
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        authStatus = "host_disconnected"
                                    }
                                }
                            }
                            break
                        }
                    }
                }
            } else {
                PeerPickerView { handle, peerName in
                    withAnimation(.easeInOut(duration: 0.28)) {
                        activeConnection = (handle, peerName)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: activeConnection != nil)
        .task {
            do {
                MirageLog.app.info("Starting LoomContext")
                try await loomContext.start()
                MirageLog.app.info("LoomContext started")
            } catch {
                MirageLog.app.fault("LoomContext start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

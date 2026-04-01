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
                    ControlView(connection: connection.handle, peerName: connection.peerName) {
                        Task { await connection.handle.disconnect() }
                        activeConnection = nil
                        authStatus = "pending"
                    }
                    .blur(radius: authStatus == "granted" ? 0 : 15)
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
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .task(id: connection.peerName) {
                    authStatus = "pending"
                    
                    Task {
                        for await event in connection.handle.events {
                            if case .disconnected = event {
                                await MainActor.run {
                                    if authStatus != "denied" {
                                        withAnimation(.spring(duration: 0.3)) {
                                            authStatus = "host_disconnected"
                                        }
                                    }
                                }
                                break
                            }
                        }
                    }
                    
                    for await data in connection.handle.messages {
                        if let msg = try? JSONDecoder().decode(ControlMessage.self, from: data) {
                            if case let .authorizationStatus(status) = msg {
                                withAnimation(.spring(duration: 0.3)) {
                                    authStatus = status
                                }
                            }
                        }
                    }
                }
            } else {
                PeerPickerView { handle, peerName in
                    withAnimation(.spring(duration: 0.45)) {
                        activeConnection = (handle, peerName)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.45), value: activeConnection != nil)
        .task {
            do {
                print("MirageControliOS: 🚀 Attempting to start LoomContext...")
                try await loomContext.start()
                print("MirageControliOS: ✅ LoomContext started successfully!")
            } catch {
                print("MirageControliOS: ❌ FATAL ERROR starting LoomContext: \(error)")
                print("MirageControliOS: Error Description: \(error.localizedDescription)")
            }
        }
    }
}

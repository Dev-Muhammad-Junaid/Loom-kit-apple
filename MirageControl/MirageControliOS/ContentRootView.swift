//
//  ContentRootView.swift
//  MirageControliOS
//

import LoomKit
import SwiftUI

struct ContentRootView: View {
    @Environment(\.loomContext) private var loomContext
    @State private var activeConnection: (handle: LoomConnectionHandle, peerName: String)?

    var body: some View {
        Group {
            if let connection = activeConnection {
                ControlView(connection: connection.handle, peerName: connection.peerName) {
                    Task { await connection.handle.disconnect() }
                    activeConnection = nil
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
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

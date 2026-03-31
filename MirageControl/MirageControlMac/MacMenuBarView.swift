//
//  MacMenuBarView.swift
//  MirageControlMac
//

import LoomKit
import SwiftUI

struct MacMenuBarView: View {
    @Environment(\.loomContext) private var loomContext
    @EnvironmentObject private var authManager: DeviceAuthorizationManager
    @LoomQuery(.connections(sort: .connectedAtDescending)) private var connections: [LoomConnectionSnapshot]

    let receiver: ControlReceiver

    @State private var accessibilityGranted = InputInjector.shared.isAccessibilityGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ────────────────────────────────────────────────
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "6C63FF"), Color(hex: "A78BFA")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: "cursorarrow.rays")
                        .foregroundStyle(.white)
                        .font(.system(size: 16, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("MirageControl")
                        .font(.system(size: 14, weight: .bold))
                    Text(loomContext.isRunning ? "Ready to receive" : "Starting…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(loomContext.isRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: loomContext.isRunning ? .green.opacity(0.6) : .orange.opacity(0.6), radius: 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // ── Body ──────────────────────────────────────────────────
            let authorizedConnections = connections.filter { $0.state == .connected && authManager.isAuthorized(peerID: $0.peerID) }
            
            if !authManager.pendingConnections.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PENDING REQUESTS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                    ForEach(authManager.pendingConnections) { connection in
                        PendingConnectionRow(connection: connection, loomContext: loomContext)
                    }
                }
                .padding(.bottom, 8)
                
                Divider()
            }

            if authorizedConnections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "ipad.and.iphone")
                        .font(.system(size: 32))
                        .foregroundStyle(Color(hex: "6C63FF").opacity(0.7))
                    Text("Waiting for iPad…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Open MirageControl on your iPad\nand select this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AUTHORIZED DEVICES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                    ForEach(authorizedConnections) { connection in
                        ConnectionRow(connection: connection, loomContext: loomContext)
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()

            // ── Accessibility warning ─────────────────────────────────
            if !accessibilityGranted {
                Button {
                    InputInjector.shared.requestAccessibility()
                    withAnimation { accessibilityGranted = InputInjector.shared.isAccessibilityGranted }
                } label: {
                    Label("Grant Accessibility Access", systemImage: "exclamationmark.shield.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Divider()
            }

            // ── Footer ────────────────────────────────────────────────
            HStack {
                Button("Quit MirageControl") { NSApplication.shared.terminate(nil) }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 270)
        .background(.regularMaterial)
    }
}

// MARK: - ConnectionRow

private struct ConnectionRow: View {
    let connection: LoomConnectionSnapshot
    let loomContext: LoomContext
    @EnvironmentObject private var authManager: DeviceAuthorizationManager
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ipad.landscape")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "6C63FF"))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.peerName)
                    .font(.system(size: 12, weight: .semibold))
                Text("Connected & Authorized")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            
            if isHovering {
                Button {
                    authManager.removeAndDisconnect(connection: connection, loomContext: loomContext)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Remove Authorization & Disconnect")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .onHover { isHovering = $0 }
    }
}

// MARK: - PendingConnectionRow

private struct PendingConnectionRow: View {
    let connection: LoomConnectionSnapshot
    let loomContext: LoomContext
    @EnvironmentObject private var authManager: DeviceAuthorizationManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.peerName)
                    .font(.system(size: 12, weight: .semibold))
                Text("Requesting mouse access")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            
            HStack(spacing: 6) {
                Button {
                    authManager.authorize(connection: connection)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Approve")
                
                Button {
                    authManager.reject(connection: connection, loomContext: loomContext)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Deny")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}

// MARK: - Color+Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:(a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}

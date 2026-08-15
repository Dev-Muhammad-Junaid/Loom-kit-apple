//
//  MacMenuBarView.swift
//  DeckHandMac
//

import Combine
import Loom
import LoomKit
import SwiftUI

struct MacMenuBarView: View {
    @Environment(\.loomContext) private var loomContext
    @EnvironmentObject private var authManager: DeviceAuthorizationManager
    @EnvironmentObject private var daemon: MacDaemon
    @LoomQuery(.connections(sort: .connectedAtDescending)) private var connections: [LoomConnectionSnapshot]
    @LoomQuery(.peers(sort: .name)) private var peers: [LoomPeerSnapshot]

    let receiver: ControlReceiver

    @ObservedObject private var permissions = PermissionsMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ────────────────────────────────────────────────
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: DeckHandTheme.headerGradientColors,
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
                    Text("Deck Hand")
                        .font(.system(size: 14, weight: .bold))
                    // Failed-start state takes precedence: without it the
                    // header sits on "Starting…" forever after a startup
                    // error and the user has no signal anything is wrong
                    // (WID-406).
                    if daemon.fatalStartupError != nil {
                        Label("Failed to start", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DeckHandTheme.danger)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Text(loomContext.isRunning ? "Ready to receive" : "Starting…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Concise, actionable detail row for the startup failure.
            if let startupError = daemon.fatalStartupError {
                Text(startupError)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

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
                        PendingConnectionRow(
                            connection: connection,
                            loomContext: loomContext,
                            deviceSystemImage: deviceSystemImage(for: connection)
                        )
                    }
                }
                .padding(.bottom, 8)
                
                Divider()
            }

            if authorizedConnections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "ipad.and.iphone")
                        .font(.system(size: 32))
                        .foregroundStyle(DeckHandTheme.violet.opacity(0.7))
                    Text("Waiting for Connection Request...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Open Deck Hand on your iPhone or iPad\nand select this Mac.")
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
                        ConnectionRow(
                            connection: connection,
                            loomContext: loomContext,
                            deviceSystemImage: deviceSystemImage(for: connection)
                        )
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()

            // ── Permissions ───────────────────────────────────────────
            // Live status per TCC permission — re-checked every 2 s while
            // the panel is open, so toggles flipped in System Settings
            // reflect immediately. Each non-granted row is tappable and
            // jumps to the exact Settings pane.
            VStack(alignment: .leading, spacing: 2) {
                Text("PERMISSIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                PermissionRow(
                    title: "Accessibility",
                    detail: "Mouse, keyboard, and dialog control",
                    status: permissions.accessibility
                ) { permissions.fixAccessibility() }

                PermissionRow(
                    title: "Screen Recording",
                    detail: "Screenshots and live mirror",
                    status: permissions.screenRecording
                ) { permissions.fixScreenRecording() }

                PermissionRow(
                    title: "Notifications",
                    detail: "Connection approval alerts",
                    status: permissions.notifications
                ) { permissions.fixNotifications() }

                if permissions.screenRecordingNeedsRelaunch {
                    Button {
                        permissions.relaunchApp()
                    } label: {
                        Label("Settings says on, but capture is denied — remove & re-add in Settings, then tap to relaunch", systemImage: "arrow.clockwise.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }

                if permissions.accessibility == .denied || permissions.screenRecording == .denied {
                    Text("Enabled it but still listed as off? Development builds change identity on every rebuild — remove Deck Hand from the Settings list and add it back.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 6)
            // Re-check on open and on a slow tick while visible — TCC has
            // no change notifications, polling is the only way.
            .onAppear { permissions.refresh() }
            .onReceive(
                Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            ) { _ in
                permissions.refresh()
            }

            Divider()

            // ── Footer ────────────────────────────────────────────────
            HStack {
                Button("Quit Deck Hand") { NSApplication.shared.terminate(nil) }
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

    /// Resolves iPhone vs iPad (etc.) from the live peer list; Deck Hand remote is iOS-only so unknown falls back to phone.
    private func deviceSystemImage(for connection: LoomConnectionSnapshot) -> String {
        guard let peer = peers.first(where: { $0.id == connection.peerID }) else {
            return DeviceType.iPhone.systemImage
        }
        switch peer.deviceType {
        case .unknown:
            return DeviceType.iPhone.systemImage
        default:
            return peer.deviceType.systemImage
        }
    }
}

// MARK: - PermissionRow

private struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionsMonitor.Status
    let onFix: () -> Void

    var body: some View {
        Button(action: { if status != .granted { onFix() } }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if status != .granted {
                    Text("Fix…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DeckHandTheme.violet)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(status == .granted ? "\(title): granted" : "Open System Settings to grant \(title)")
    }

    private var icon: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .denied: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .granted: DeckHandTheme.success
        case .denied: .orange
        case .unknown: .secondary
        }
    }
}

// MARK: - ConnectionRow

private struct ConnectionRow: View {
    let connection: LoomConnectionSnapshot
    let loomContext: LoomContext
    let deviceSystemImage: String
    @EnvironmentObject private var authManager: DeviceAuthorizationManager
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: deviceSystemImage)
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DeckHandTheme.violet)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.peerName)
                    .font(.system(size: 12, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text("Connected \(connection.connectedAt, style: .relative) ago")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                // Surface the live connection id for matching against the iPad
                // and spotting silent session swaps.
                Text("session \(connection.id.uuidString.prefix(8))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
                    .foregroundStyle(DeckHandTheme.success)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .onHover { isHovering = $0 }
    }
}

// MARK: - PendingConnectionRow

private struct PendingConnectionRow: View {
    let connection: LoomConnectionSnapshot
    let loomContext: LoomContext
    let deviceSystemImage: String
    @EnvironmentObject private var authManager: DeviceAuthorizationManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: deviceSystemImage)
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DeckHandTheme.warning)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.peerName)
                    .font(.system(size: 12, weight: .semibold))
                Text("Requesting mouse access")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let requestedAt = authManager.pendingRequestedDate(for: connection.id) {
                    Text("Pending \(requestedAt, style: .relative) ago")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()

            HStack(spacing: 6) {
                // One decision, no modes: Allow (this session) or Deny.
                Button {
                    authManager.authorize(connection: connection)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DeckHandTheme.success)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Allow for this session")

                Button {
                    authManager.reject(connection: connection, loomContext: loomContext)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DeckHandTheme.danger)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Deny")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

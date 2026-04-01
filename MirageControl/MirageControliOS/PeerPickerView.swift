//
//  PeerPickerView.swift
//  MirageControliOS
//

import Loom
import LoomKit
import SwiftUI

struct PeerPickerView: View {
    let onConnected: (LoomConnectionHandle, String) -> Void

    @Environment(\.loomContext) private var loomContext
    @Environment(\.colorScheme) private var colorScheme
    @LoomQuery(.peers(sort: .name)) private var peers: [LoomPeerSnapshot]

    @State private var connecting: UUID?
    @State private var errorMessage: String?

    // MARK: - Adaptive colours

    private var bg: Color {
        colorScheme == .dark ? Color(hex: "0A0A0F") : Color(UIColor.systemGroupedBackground)
    }
    private var cardFill: Color {
        colorScheme == .dark ? .white.opacity(0.07) : Color(UIColor.systemBackground)
    }
    private var cardBorder: Color {
        colorScheme == .dark ? .white.opacity(0.1) : Color.primary.opacity(0.08)
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ────────────────────────────────────────────
                header

                // ── Peer list ─────────────────────────────────────────
                if peers.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(peers) { peer in
                                PeerRow(
                                    peer: peer,
                                    isConnecting: connecting == peer.deviceID,
                                    colorScheme: colorScheme
                                ) {
                                    connectTo(peer)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                // ── Error banner ──────────────────────────────────────
                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.75).clipShape(RoundedRectangle(cornerRadius: 12)))
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer()

                Text("Make sure your Mac is on the same Wi-Fi network")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            // Icon: original cursorarrow.rays, no glowing blob
            ZStack {
                Circle()
                    .fill(cardFill)
                    .overlay(Circle().strokeBorder(cardBorder, lineWidth: 1))
                    .frame(width: 96, height: 96)

                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 38, weight: .thin))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.primary)
            }

            VStack(spacing: 6) {
                Text("MirageControl")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                Text("Choose a Mac to control")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.top, 72)
        .padding(.bottom, 44)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.3)
            Text("Searching for Macs…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Actions

    private func connectTo(_ peer: LoomPeerSnapshot) {
        guard connecting == nil else { return }
        connecting = peer.deviceID
        errorMessage = nil

        Task {
            do {
                let handle = try await loomContext.connect(peer)
                await MainActor.run {
                    connecting = nil
                    onConnected(handle, peer.name)
                }
            } catch {
                await MainActor.run {
                    connecting = nil
                    withAnimation {
                        errorMessage = "Connection failed: \(error.localizedDescription)"
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation { errorMessage = nil }
                    }
                }
            }
        }
    }
}

// MARK: - PeerRow

private struct PeerRow: View {
    let peer: LoomPeerSnapshot
    let isConnecting: Bool
    let colorScheme: ColorScheme
    let onTap: () -> Void

    @State private var isPressed = false

    private var cardFill: Color {
        colorScheme == .dark
            ? .white.opacity(isPressed ? 0.12 : 0.07)
            : Color(UIColor.systemBackground).opacity(isPressed ? 0.9 : 1.0)
    }
    private var cardBorder: Color {
        colorScheme == .dark ? .white.opacity(0.1) : Color.primary.opacity(0.07)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Mac icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 46, height: 46)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 20, weight: .thin))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.primary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(peer.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(peer.isNearby ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(peer.isNearby ? "Nearby" : "Remote")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                    }
                }

                Spacer()

                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.9)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(cardBorder, lineWidth: 1)
                    )
                    .shadow(
                        color: colorScheme == .dark ? .clear : .black.opacity(0.04),
                        radius: 6, y: 2
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.spring(duration: 0.2), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}

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
    @LoomQuery(.peers(sort: .name)) private var peers: [LoomPeerSnapshot]

    @State private var connecting: UUID?
    @State private var errorMessage: String?
    @State private var pulseAnim = false

    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [Color(hex: "0F0C29"), Color(hex: "302B63"), Color(hex: "24243E")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Logo / header ─────────────────────────────────────
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(colors: [Color(hex: "6C63FF").opacity(0.4), .clear],
                                               center: .center, startRadius: 20, endRadius: 80)
                            )
                            .frame(width: 120, height: 120)
                            .scaleEffect(pulseAnim ? 1.15 : 1.0)
                            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true),
                                       value: pulseAnim)

                        Image(systemName: "cursorarrow.rays")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 52, height: 52)
                            .foregroundStyle(
                                LinearGradient(colors: [Color(hex: "A78BFA"), Color(hex: "6C63FF")],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                    }

                    Text("MirageControl")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Select a Mac to control")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 60)
                .padding(.bottom, 40)
                .onAppear { pulseAnim = true }

                // ── Peer list ─────────────────────────────────────────
                if peers.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(peers) { peer in
                                PeerRow(
                                    peer: peer,
                                    isConnecting: connecting == peer.deviceID
                                ) {
                                    connectTo(peer)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                // ── Error banner ──────────────────────────────────────
                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.7).clipShape(RoundedRectangle(cornerRadius: 12)))
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer()

                Text("Make sure your Mac is on the same Wi-Fi network")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.3)
            Text("Searching for Macs…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
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
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: "6C63FF").opacity(0.25))
                        .frame(width: 48, height: 48)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 22))
                        .foregroundStyle(Color(hex: "A78BFA"))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(peer.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(peer.isNearby ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(peer.isNearby ? "Nearby" : "Remote")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Spacer()

                if isConnecting {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.9)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white.opacity(isPressed ? 0.12 : 0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
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



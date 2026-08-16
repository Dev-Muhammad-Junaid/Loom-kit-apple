//
//  PeerPickerView.swift
//  DeckHandiOS
//

import Loom
import LoomKit
import SwiftUI

struct PeerPickerView: View {
    let onConnected: (LoomConnectionHandle, String) -> Void

    @Environment(\.loomContext) private var loomContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LoomQuery(.peers(sort: .name)) private var peers: [LoomPeerSnapshot]

    @State private var connecting: UUID?
    @State private var errorMessage: String?
    @State private var isSettingsPresented = false

    private enum Layout {
        /// Caps the content column so cards stay a readable width on a 13"
        /// iPad instead of stretching the full display.
        static let column: CGFloat = 520
    }

    var body: some View {
        ZStack {
            DeckHandTheme.brandBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Centred while the content is short, scrolls once there are
                // more Macs than fit. On an iPad the column is capped so the
                // cards don't stretch into letterboxes.
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            header
                            if peers.isEmpty {
                                searchingState
                            } else {
                                peerList
                            }
                        }
                        .frame(maxWidth: Layout.column)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                    }
                    .scrollIndicators(.hidden)
                }

                if let error = errorMessage {
                    errorBanner(error)
                }

                footer
            }

            // Reachable before connecting: appearance, pointer feel and the
            // welcome tour are all worth changing without a Mac in range.
            settingsButton
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        // The picker is a branded surface, not a system one: it stays dark
        // regardless of the appearance preference, the same way the icon does.
        .preferredColorScheme(.dark)
    }

    private var settingsButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle().fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Settings")
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 26) {
            DeckHandMark(size: 132)

            VStack(spacing: 8) {
                Text("Deck Hand")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(peers.isEmpty ? "Looking for your Mac" : "Choose a Mac to control")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .contentTransition(.opacity)
            }
        }
        .padding(.top, 32)
        .padding(.bottom, 40)
    }

    // MARK: - Peers

    private var peerList: some View {
        // The user's own iCloud Macs first (stable within each group thanks
        // to the query's name sort) — they're the ones that connect without
        // an approval prompt.
        let orderedPeers = peers.sorted {
            ($0.isSameICloudDevice ? 0 : 1, $0.name) < ($1.isSameICloudDevice ? 0 : 1, $1.name)
        }

        return VStack(spacing: 10) {
            ForEach(Array(orderedPeers.enumerated()), id: \.element.id) { index, peer in
                PeerCard(
                    peer: peer,
                    isConnecting: connecting == peer.deviceID,
                    isDimmed: connecting != nil && connecting != peer.deviceID
                ) {
                    connectTo(peer)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.2)
                        : .spring(duration: 0.38, bounce: 0.14).delay(Double(index) * 0.05),
                    value: orderedPeers.count
                )
            }
        }
        .padding(.horizontal, 22)
    }

    private var searchingState: some View {
        VStack(spacing: 16) {
            RadarPulse()
            Text("Make sure Deck Hand is open on your Mac")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .padding(.top, 12)
    }

    // MARK: - Footer

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(DeckHandTheme.danger)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: DeckHandTheme.Radius.sm, style: .continuous)
                    .fill(DeckHandTheme.danger.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: DeckHandTheme.Radius.sm, style: .continuous)
                            .strokeBorder(DeckHandTheme.danger.opacity(0.28), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "wifi")
                .font(.system(size: 11, weight: .medium))
            Text("Both devices on the same Wi-Fi")
                .font(.system(size: 12, weight: .regular, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.32))
        .padding(.top, 20)
        .padding(.bottom, 34)
    }

    // MARK: - Actions

    private func connectTo(_ peer: LoomPeerSnapshot) {
        guard connecting == nil else { return }
        connecting = peer.deviceID
        errorMessage = nil

        DeckHandLog.connection.info("📡 Connecting to \(peer.name, privacy: .public) id=\(peer.deviceID, privacy: .public) nearby=\(peer.isNearby)")
        Task {
            do {
                let handle = try await loomContext.connect(peer)
                await MainActor.run {
                    DeckHandLog.connection.info("📡 Connected to \(peer.name, privacy: .public); awaiting authorization")
                    connecting = nil
                    onConnected(handle, peer.name)
                }
            } catch {
                await MainActor.run {
                    DeckHandLog.connection.error("📡 Connect failed for \(peer.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    connecting = nil
                    withAnimation(.easeOut(duration: 0.22)) {
                        errorMessage = "Connection failed: \(error.localizedDescription)"
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation(.easeOut(duration: 0.22)) { errorMessage = nil }
                    }
                }
            }
        }
    }
}

// MARK: - PeerCard

private struct PeerCard: View {
    let peer: LoomPeerSnapshot
    let isConnecting: Bool
    /// Set while a different peer is connecting, so the tapped card is the
    /// only one that still reads as active.
    let isDimmed: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 15) {
                icon

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(peer.name)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        // Provably the user's own device (private CloudKit
                        // DB record) — connects without an approval prompt.
                        if peer.isSameICloudDevice {
                            Text("My Mac")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(DeckHandTheme.Brand.mint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(
                                    Capsule().fill(DeckHandTheme.Brand.mint.opacity(0.14))
                                )
                        }
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(peer.isNearby ? DeckHandTheme.Brand.mint : DeckHandTheme.warning)
                            .frame(width: 5, height: 5)
                        Text(peer.isNearby ? "Nearby" : "Remote")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }

                Spacer(minLength: 8)

                if isConnecting {
                    ProgressView()
                        .tint(.white.opacity(0.7))
                        .transition(.opacity)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.28))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: DeckHandTheme.Radius.xl, style: .continuous)
                    .fill(DeckHandTheme.Brand.unlitTileGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: DeckHandTheme.Radius.xl, style: .continuous)
                            .strokeBorder(
                                isConnecting
                                    ? DeckHandTheme.Brand.glow.opacity(0.55)
                                    : Color.white.opacity(0.09),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: DeckHandTheme.Brand.glow.opacity(isConnecting ? 0.32 : 0),
                        radius: 18
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DeckHandTheme.Radius.xl, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(isDimmed ? 0.4 : 1)
        .disabled(isConnecting || isDimmed)
        .animation(.easeOut(duration: 0.22), value: isConnecting)
        .animation(.easeOut(duration: 0.22), value: isDimmed)
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DeckHandTheme.Brand.glow.opacity(0.16))
                .frame(width: 44, height: 44)
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DeckHandTheme.Brand.litTileGradient)
        }
    }
}

// MARK: - Radar pulse

/// Expanding rings while no Mac has been found yet. Slow and quiet — this
/// runs indefinitely, so it can't be attention-grabbing.
private struct RadarPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .strokeBorder(DeckHandTheme.Brand.glow.opacity(0.35), lineWidth: 1)
                        .frame(width: 44, height: 44)
                        .scaleEffect(isPulsing ? 2.6 : 0.9)
                        .opacity(isPulsing ? 0 : 0.9)
                        .animation(
                            .easeOut(duration: 2.4)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.8),
                            value: isPulsing
                        )
                }
            }

            Circle()
                .fill(DeckHandTheme.Brand.glow.opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DeckHandTheme.Brand.glow)
                )
        }
        .frame(width: 120, height: 120)
        .onAppear { isPulsing = true }
        .accessibilityLabel("Searching for Macs")
    }
}

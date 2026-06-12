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

    var body: some View {
        ZStack {
            // Hero sunset shader background — see `MirageTheme.heroSunsetBackground()`
            MirageTheme.heroSunsetBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ────────────────────────────────────────────
                header

                // ── Peer list ─────────────────────────────────────────
                if peers.isEmpty {
                    emptyState
                    Spacer()
                } else {
                    // The user's own iCloud Macs first (stable within each
                    // group thanks to the query's name sort) — they're the
                    // ones that connect without an approval prompt.
                    let orderedPeers = peers.sorted {
                        ($0.isSameICloudDevice ? 0 : 1, $0.name) < ($1.isSameICloudDevice ? 0 : 1, $1.name)
                    }
                    List {
                        Section {
                            ForEach(orderedPeers) { peer in
                                PeerRow(
                                    peer: peer,
                                    isConnecting: connecting == peer.deviceID
                                ) {
                                    connectTo(peer)
                                }
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.regularMaterial)
                                )
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }

                // ── Error banner ──────────────────────────────────────
                if let error = errorMessage {
                    Text(error)
                        .font(MirageTheme.TypeStyle.captionRounded)
                        .foregroundStyle(MirageTheme.errorBannerLabel(colorScheme))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            MirageTheme.errorBannerFill(colorScheme)
                                .clipShape(RoundedRectangle(cornerRadius: MirageTheme.Radius.sm, style: .continuous))
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .transition(.opacity)
                }

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
            // Rose Three parametric loader (remote app branding)
            RoseThreeLoaderView(size: 108, color: MirageTheme.violet)

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
        .padding(.bottom, 24)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        MirageLoadingStateView(title: "Searching for Macs…")
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

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(MirageTheme.violet)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(peer.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        // Provably the user's own device (private CloudKit
                        // DB record) — connects without an approval prompt.
                        if peer.isSameICloudDevice {
                            Label("My Mac", systemImage: "icloud.fill")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(MirageTheme.violet)
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(MirageTheme.violet.opacity(0.12))
                                )
                        }
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(peer.isNearby ? MirageTheme.success : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(peer.isNearby ? "Nearby" : "Remote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isConnecting {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

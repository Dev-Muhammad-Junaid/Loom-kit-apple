//
//  ControlView.swift
//  MirageControliOS
//

import LoomKit
import SwiftUI

struct ControlView: View {
    let connection: LoomConnectionHandle
    let peerName: String
    let onDisconnect: () -> Void

    @State private var selectedTab: Tab = .trackpad
    @State private var sender: TrackpadSender?

    enum Tab: String, CaseIterable {
        case trackpad = "Trackpad"
        case streamdeck = "StreamDeck"

        var icon: String {
            switch self {
            case .trackpad:   "hand.draw"
            case .streamdeck: "rectangle.grid.3x2"
            }
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0F0C29"), Color(hex: "1A1A2E")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            if let sender {
                VStack(spacing: 0) {
                    // ── Nav bar ────────────────────────────────────────
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peerName)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                    .shadow(color: .green.opacity(0.8), radius: 3)
                                Text("Connected")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }

                        Spacer()

                        Button {
                            onDisconnect()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                Text("Disconnect")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(.white.opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                    // ── Tab switcher ───────────────────────────────────
                    HStack(spacing: 0) {
                        ForEach(Tab.allCases, id: \.self) { tab in
                            TabPill(
                                tab: tab,
                                isSelected: selectedTab == tab
                            ) {
                                withAnimation(.spring(duration: 0.3)) {
                                    selectedTab = tab
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)

                    // ── Content ────────────────────────────────────────
                    Group {
                        switch selectedTab {
                        case .trackpad:
                            TrackpadView(sender: sender)
                        case .streamdeck:
                            StreamDeckGridView(sender: sender)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: selectedTab)
                }
            } else {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
            }
        }
        .task {
            sender = TrackpadSender(handle: connection)
        }
    }
}

// MARK: - TabPill

private struct TabPill: View {
    let tab: ControlView.Tab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(tab.rawValue)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color(hex: "6C63FF").opacity(0.8) : .clear)
                    .animation(.spring(duration: 0.3), value: isSelected)
            )
        }
        .buttonStyle(.plain)
    }
}



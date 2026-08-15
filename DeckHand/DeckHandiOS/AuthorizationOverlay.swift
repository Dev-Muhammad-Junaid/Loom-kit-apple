//
//  AuthorizationOverlay.swift
//  DeckHandiOS
//

import SwiftUI

struct AuthorizationOverlay: View {
    let status: String
    let peerName: String
    let onDisconnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// True when the only sensible action is to dismiss the overlay (the
    /// connection is already gone). Drives both the button label and its
    /// destructive role.
    private var isTerminalState: Bool {
        status == "denied" || status == "host_disconnected"
    }

    var body: some View {
        ZStack {
            DeckHandTheme.authScrim(colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                statusContent
                disconnectButton.padding(.top, 8)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .background(cardBackground)
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Native button (matches main-page toolbar styling)
    //
    // iOS 26 picks up Liquid Glass via `.glass`. The destructive role tints
    // the label red (matching the main-page disconnect button). On iOS 17
    // we fall back to `.bordered`, which gives the same shape language.

    @ViewBuilder
    private var disconnectButton: some View {
        let label = isTerminalState ? "Dismiss" : "Disconnect"
        let role: ButtonRole? = isTerminalState ? .cancel : .destructive
        // Compile-time guard, not just runtime: `.glass` only exists in the
        // iOS 26 SDK (Xcode 26 / Swift 6.2). On Xcode 16 the whole branch
        // would fail to compile, so gate it out and use `.bordered`.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Button(label, role: role, action: onDisconnect)
                .buttonStyle(.glass)
                .controlSize(.large)
        } else {
            Button(label, role: role, action: onDisconnect)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        #else
        Button(label, role: role, action: onDisconnect)
            .buttonStyle(.bordered)
            .controlSize(.large)
        #endif
    }

    // MARK: - Native dialog card (Liquid Glass on iOS 26, material on iOS 17)

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DeckHandTheme.Radius.xxl, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            shape
                .fill(.regularMaterial)
                .glassEffect(in: shape)
        } else {
            shape
                .fill(.regularMaterial)
                .shadow(color: DeckHandTheme.dialogCardShadow(colorScheme), radius: 24, y: 12)
        }
        #else
        shape
            .fill(.regularMaterial)
            .shadow(color: DeckHandTheme.dialogCardShadow(colorScheme), radius: 24, y: 12)
        #endif
    }

    @ViewBuilder
    private var statusContent: some View {
        switch status {
        case "pending":
            statusBlock(
                systemImage: "lock.display",
                title: "Waiting for Approval",
                message: "Please allow the connection request on \(peerName).",
                pulse: true
            )

        case "host_disconnected":
            statusBlock(
                systemImage: "wifi.slash",
                title: "Disconnected",
                message: "The connection to \(peerName) was closed."
            )

        case "denied":
            statusBlock(
                systemImage: "xmark.shield.fill",
                title: "Access Denied",
                message: "Your request to control \(peerName) was declined."
            )

        default:
            VStack(spacing: 16) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: DeckHandTheme.StatusIcon.size))
                    .foregroundStyle(Color.secondary)

                Text("Unknown state")
                    .font(DeckHandTheme.TypeStyle.titleRounded)
                    .foregroundStyle(Color.primary)
            }
        }
    }

    /// Shared layout for the three concrete status states (pending /
    /// disconnected / denied). Pulls icon colors from
    /// `DeckHandTheme.StatusIcon.colors(for:)` so the palette stays
    /// consistent with any other dialog using the same status strings.
    @ViewBuilder
    private func statusBlock(
        systemImage: String,
        title: String,
        message: String,
        pulse: Bool = false
    ) -> some View {
        let palette = DeckHandTheme.StatusIcon.colors(for: status)
        VStack(spacing: 16) {
            Group {
                if pulse {
                    Image(systemName: systemImage)
                        .symbolEffect(.pulse, options: .repeating)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .font(.system(size: DeckHandTheme.StatusIcon.size))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(palette.primary, palette.secondary)

            VStack(spacing: 8) {
                Text(title)
                    .font(DeckHandTheme.TypeStyle.titleRounded)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(DeckHandTheme.TypeStyle.bodyRounded)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

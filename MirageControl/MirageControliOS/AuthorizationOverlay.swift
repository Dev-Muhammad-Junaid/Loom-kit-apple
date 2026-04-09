//
//  AuthorizationOverlay.swift
//  MirageControliOS
//

import SwiftUI

struct AuthorizationOverlay: View {
    let status: String
    let peerName: String
    let onDisconnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            MirageTheme.authScrim(colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                statusContent

                Button(action: onDisconnect) {
                    Text((status == "denied" || status == "host_disconnected") ? "Dismiss" : "Disconnect")
                        .font(MirageTheme.TypeStyle.buttonRounded)
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(MirageTheme.authSecondaryButtonFill(colorScheme))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(MirageTheme.authSecondaryButtonBorder(colorScheme), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: MirageTheme.Radius.xxl, style: .continuous)
                    .fill(MirageTheme.authCardFill(colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: MirageTheme.Radius.xxl, style: .continuous)
                            .strokeBorder(MirageTheme.authCardBorder(colorScheme), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 24, y: 12)
            )
            .padding(.horizontal, 28)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch status {
        case "pending":
            VStack(spacing: 16) {
                Image(systemName: "lock.display")
                    .font(.system(size: 52))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(MirageTheme.violet, MirageTheme.violet.opacity(0.45))
                    .symbolEffect(.pulse, options: .repeating)

                VStack(spacing: 8) {
                    Text("Waiting for Approval")
                        .font(MirageTheme.TypeStyle.titleRounded)
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.center)

                    Text("Please allow the connection request on \(peerName).")
                        .font(MirageTheme.TypeStyle.bodyRounded)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                }
            }

        case "host_disconnected":
            VStack(spacing: 16) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 52))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.orange, Color.orange.opacity(0.5))

                VStack(spacing: 8) {
                    Text("Disconnected")
                        .font(MirageTheme.TypeStyle.titleRounded)
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.center)

                    Text("The connection to \(peerName) was closed.")
                        .font(MirageTheme.TypeStyle.bodyRounded)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                }
            }

        case "denied":
            VStack(spacing: 16) {
                Image(systemName: "xmark.shield.fill")
                    .font(.system(size: 52))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.red, Color.red.opacity(0.45))

                VStack(spacing: 8) {
                    Text("Access Denied")
                        .font(MirageTheme.TypeStyle.titleRounded)
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.center)

                    Text("Your request to control \(peerName) was declined.")
                        .font(MirageTheme.TypeStyle.bodyRounded)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                }
            }

        default:
            VStack(spacing: 16) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.secondary)

                Text("Unknown state")
                    .font(MirageTheme.TypeStyle.titleRounded)
                    .foregroundStyle(Color.primary)
            }
        }
    }
}

//
//  ControlView.swift
//  MirageControliOS
//

import LoomKit
import SwiftUI

struct ControlView: View {
    let connection: LoomConnectionHandle
    let peerName: String
    let onAuthStatusChanged: (String) -> Void
    let onDisconnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: Tab = .trackpad
    @State private var sender: TrackpadSender?

    // Bidirectional state
    @State private var activeAppName: String?
    @State private var screenshotImage: UIImage?
    @State private var isRequestingScreenshot = false   // in-flight guard
    @State private var isScreenshotPresented = false
    @State private var screenshotTimeoutTask: Task<Void, Never>?
    @State private var screenshotErrorMessage: String?

    enum Tab: String, CaseIterable {
        case trackpad   = "Trackpad"
        case streamdeck = "Stream Deck"

        var icon: String {
            switch self {
            case .trackpad:   "hand.draw"
            case .streamdeck: "square.grid.3x2"
            }
        }
    }

    // MARK: - Adaptive colours

    private var bg: Color {
        colorScheme == .dark ? Color(hex: "0A0A0F") : Color(UIColor.systemGroupedBackground)
    }
    private var navBorder: Color {
        colorScheme == .dark ? .white.opacity(0.07) : Color.primary.opacity(0.08)
    }
    private var tabContainerFill: Color {
        colorScheme == .dark ? .white.opacity(0.06) : Color(UIColor.systemFill)
    }
    private var tabContainerBorder: Color {
        colorScheme == .dark ? .white.opacity(0.09) : Color.primary.opacity(0.06)
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            if let sender {
                VStack(spacing: 0) {
                    navBar
                    Divider().overlay(navBorder)
                    tabSwitcher
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider().overlay(navBorder)

                    Group {
                        switch selectedTab {
                        case .trackpad:
                            TrackpadView(sender: sender, colorScheme: colorScheme)
                        case .streamdeck:
                            StreamDeckGridView(sender: sender, colorScheme: colorScheme)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: selectedTab)
                }
            } else {
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.3)
                    Text("Initializing…")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        // Screenshot sheet
        .fullScreenCover(isPresented: $isScreenshotPresented) {
            ZStack {
                if let img = screenshotImage {
                    ScreenshotPreviewView(image: img) {
                        isScreenshotPresented = false
                    }
                } else {
                    // Loading state while waiting for Mac response
                    ZStack {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 18) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.4)
                            Text("Capturing screen…")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                            Button("Cancel") {
                                screenshotTimeoutTask?.cancel()
                                isScreenshotPresented = false
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
            }
        }
        .alert("Screenshot Failed", isPresented: Binding(
            get: { screenshotErrorMessage != nil },
            set: { if !$0 { screenshotErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { screenshotErrorMessage = nil }
        } message: {
            Text(screenshotErrorMessage ?? "")
        }
        .task {
            sender = TrackpadSender(handle: connection)
            // Single consolidated message loop — no competing consumers
            await listenForHostMessages()
        }
    }

    // MARK: - Single Message Listener
    //
    // All messages from the Mac come through here. Splitting this loop
    // across multiple views causes AsyncSequence racing where messages get
    // silently consumed by the wrong listener.

    private func listenForHostMessages() async {
        for await data in connection.messages {
            guard let message = try? JSONDecoder().decode(ControlMessage.self, from: data) else {
                continue
            }
            await MainActor.run {
                switch message {
                case let .authorizationStatus(status):
                    onAuthStatusChanged(status)

                case let .activeAppUpdate(name, _):
                    withAnimation(.easeInOut(duration: 0.2)) {
                        activeAppName = name
                    }

                case let .screenshotData(data):
                    screenshotTimeoutTask?.cancel()
                    isRequestingScreenshot = false
                    if let img = UIImage(data: data) {
                        screenshotImage = img
                        // isScreenshotPresented is already true; ZStack swaps to ScreenshotPreviewView
                    } else {
                        // Data arrived but was not a valid image
                        isScreenshotPresented = false
                        screenshotErrorMessage = "Received invalid image data from Mac."
                    }

                case let .screenshotError(message):
                    screenshotTimeoutTask?.cancel()
                    isRequestingScreenshot = false
                    isScreenshotPresented = false
                    screenshotErrorMessage = message

                default:
                    break
                }
            }
        }
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(peerName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(hex: "22C55E"))
                        .frame(width: 6, height: 6)
                        .shadow(color: Color(hex: "22C55E").opacity(0.8), radius: 4)

                    if let app = activeAppName {
                        Text(app)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.secondary)
                            .id(app)
                    } else {
                        Text("Connected")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 12) {
                // Screenshot button — disabled while a request is already in-flight
                Button(action: {
                    guard !isRequestingScreenshot else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()

                    // Reset state before opening the sheet
                    screenshotImage = nil
                    screenshotErrorMessage = nil
                    isRequestingScreenshot = true
                    isScreenshotPresented = true

                    Task { await sender?.requestScreenshot() }

                    // Cancel any previous timeout and start a fresh 8-second window
                    screenshotTimeoutTask?.cancel()
                    screenshotTimeoutTask = Task { @MainActor in
                        do {
                            try await Task.sleep(nanoseconds: 8_000_000_000)
                        } catch {
                            return // Cancelled because image/error arrived — nothing to do
                        }
                        // Sleep completed naturally — Mac never responded
                        isRequestingScreenshot = false
                        isScreenshotPresented = false
                        screenshotErrorMessage = "The Mac didn't respond in time. Make sure Screen Recording is allowed in System Settings > Privacy & Security > Screen Recording."
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(isRequestingScreenshot
                                  ? Color.primary.opacity(0.04)
                                  : Color.primary.opacity(0.07))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                            .frame(width: 36, height: 36)

                        if isRequestingScreenshot {
                            ProgressView()
                                .scaleEffect(0.65)
                                .tint(Color.primary.opacity(0.5))
                        } else {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.primary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRequestingScreenshot)

                // Disconnect button
                Button(action: onDisconnect) {
                    HStack(spacing: 5) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12))
                        Text("Disconnect")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.07))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Tab Switcher

    private var tabSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { tab in
                TabPill(tab: tab, isSelected: selectedTab == tab, colorScheme: colorScheme) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                        selectedTab = tab
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tabContainerFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(tabContainerBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - TabPill

private struct TabPill: View {
    let tab: ControlView.Tab
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    private var activeFill: Color {
        colorScheme == .dark ? .white.opacity(0.14) : Color(UIColor.systemBackground)
    }
    private var activeShadow: Color {
        colorScheme == .dark ? .clear : .black.opacity(0.06)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? activeFill : Color.clear)
                    .shadow(color: activeShadow, radius: 4, y: 1)
                    .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isSelected)
            )
        }
        .buttonStyle(.plain)
    }
}

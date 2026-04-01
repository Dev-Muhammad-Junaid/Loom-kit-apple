//
//  StreamDeckGridView.swift
//  MirageControliOS
//

import SwiftUI
import UIKit

// MARK: - Grid View

struct StreamDeckGridView: View {
    let sender: TrackpadSender
    let colorScheme: ColorScheme

    @State private var deck: [MacroItem] = MacroItem.defaultDeck

    // 4-column grid — tight, gallery-style
    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(deck) { item in
                    DeckButton(item: item, colorScheme: colorScheme) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task { await sender.sendMacro(item.id) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Color.clear)
    }
}

// MARK: - DeckButton

struct DeckButton: View {
    let item: MacroItem
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                iconView
                    .frame(width: 52, height: 52)

                Text(item.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .scaleEffect(isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }

    // MARK: - Icon rendering

    @ViewBuilder
    private var iconView: some View {
        switch item {
        case .app(let app):
            AppIconView(app: app)

        case .shortcut(let shortcut):
            ShortcutIconView(shortcut: shortcut)
        }
    }
}

// MARK: - App Icon View (real icon via AsyncImage + fallback)

private struct AppIconView: View {
    let app: AppShortcut

    var body: some View {
        // Try loading the real macOS icon from a CDN; fall back to SF Symbol
        AsyncImage(url: URL(string: "https://icon.horse/icon/\(app.bundleID)")) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

            case .failure, .empty:
                fallbackIcon

            @unknown default:
                fallbackIcon
            }
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: app.sfSymbol)
            .font(.system(size: 48, weight: .thin))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(accentColor)
    }

    private var accentColor: Color {
        switch app.id {
        case "safari":   return Color(hex: "0EA5E9")
        case "xcode":    return Color(hex: "147EFB")
        case "vscode":   return Color(hex: "007ACC")
        case "terminal": return Color(hex: "2D2D2D")
        case "finder":   return Color(hex: "4A9EFF")
        case "slack":    return Color(hex: "4A154B")
        case "mail":     return Color(hex: "3B82F6")
        case "calendar": return Color(hex: "E53E3E")
        default:         return Color(hex: "5856D6")
        }
    }
}

// MARK: - Shortcut Icon View

private struct ShortcutIconView: View {
    let shortcut: SystemShortcut

    var body: some View {
        Image(systemName: shortcut.sfSymbol)
            .font(.system(size: 48, weight: .thin))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color(hex: "A78BFA"))
    }
}

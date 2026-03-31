//
//  StreamDeckGridView.swift
//  MirageControliOS
//

import SwiftUI
import UIKit

struct StreamDeckGridView: View {
    let sender: TrackpadSender

    @State private var deck: [MacroItem] = MacroItem.defaultDeck
    @State private var editingIndex: Int?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(deck.enumerated()), id: \.element.id) { index, item in
                    DeckButton(item: item) {
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        Task {
                            await sender.sendMacro(item.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(
            LinearGradient(
                colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - DeckButton

struct DeckButton: View {
    let item: MacroItem
    let action: () -> Void

    @State private var isPressed = false

    private var buttonColor: Color {
        switch item {
        case .app(let a):
            switch a.id {
            case "safari":   return Color(hex: "0EA5E9")
            case "xcode":    return Color(hex: "147EFB")
            case "vscode":   return Color(hex: "007ACC")
            case "terminal": return Color(hex: "1A1A1A")
            case "finder":   return Color(hex: "3B82F6")
            case "slack":    return Color(hex: "4A154B")
            case "mail":     return Color(hex: "2563EB")
            case "calendar": return Color(hex: "E53E3E")
            default: return Color(hex: "374151")
            }
        case .shortcut:
            return Color(hex: "6C63FF")
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: item.sfSymbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(height: 34)

                Text(item.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [
                                buttonColor.opacity(isPressed ? 1.0 : 0.85),
                                buttonColor.opacity(isPressed ? 0.7 : 0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: buttonColor.opacity(0.4), radius: isPressed ? 4 : 10, y: isPressed ? 2 : 6)
            )
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}


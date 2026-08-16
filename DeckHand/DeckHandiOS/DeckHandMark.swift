//
//  DeckHandMark.swift
//  DeckHandiOS
//
//  The app icon rebuilt as a live view: a 3×3 grid of glass tiles, one lit
//  violet at the centre and one outlined mint at the top right. Used on the
//  first-run surfaces so they read as the icon the user just tapped.
//

import SwiftUI

struct DeckHandMark: View {
    /// Overall edge length of the grid.
    var size: CGFloat = 132
    /// Plays the entrance stagger. Off for static contexts like a nav bar.
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    private var gap: CGFloat { size * 0.075 }
    private var tile: CGFloat { (size - gap * 2) / 3 }
    private var corner: CGFloat { tile * 0.30 }

    /// Row-major index of the lit tile (centre) and the mint one (top right).
    private let litIndex = 4
    private let mintIndex = 2

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        tileView(at: row * 3 + column)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animated else {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { hasAppeared = true }
                return
            }
            hasAppeared = true
        }
        .accessibilityElement()
        .accessibilityLabel("Deck Hand")
    }

    @ViewBuilder
    private func tileView(at index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        Group {
            switch index {
            case litIndex:
                shape
                    .fill(DeckHandTheme.Brand.litTileGradient)
                    .overlay(
                        // The icon's tile has a bright inner lip where the
                        // glass catches the light, not a flat fill.
                        shape.strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                    )
                    .shadow(color: DeckHandTheme.Brand.glow.opacity(0.85), radius: tile * 0.42)
                    .shadow(color: DeckHandTheme.Brand.glowSoft.opacity(0.45), radius: tile * 0.9)

            case mintIndex:
                shape
                    .fill(DeckHandTheme.Brand.unlitTileGradient)
                    .overlay(
                        shape.strokeBorder(DeckHandTheme.Brand.mint.opacity(0.9), lineWidth: 1.4)
                    )
                    .shadow(color: DeckHandTheme.Brand.mint.opacity(0.5), radius: tile * 0.3)

            default:
                shape
                    .fill(DeckHandTheme.Brand.unlitTileGradient)
                    .overlay(
                        shape.strokeBorder(DeckHandTheme.Brand.tileStroke, lineWidth: 1)
                    )
                    // Unlit tiles nearest the core pick up a little of its
                    // spill, which is what stops the grid looking flat.
                    .shadow(color: DeckHandTheme.Brand.glow.opacity(spill(for: index)), radius: tile * 0.35)
            }
        }
        .frame(width: tile, height: tile)
        .scaleEffect(hasAppeared ? 1 : 0.94)
        .opacity(hasAppeared ? 1 : 0)
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.2)
                : .spring(duration: 0.42, bounce: 0.18).delay(entranceDelay(for: index)),
            value: hasAppeared
        )
    }

    /// Violet bleed onto unlit neighbours, strongest for the tiles that share
    /// an edge with the lit centre.
    private func spill(for index: Int) -> Double {
        switch index {
        case 1, 3, 5, 7: return 0.30
        default: return 0.12
        }
    }

    /// Radiates outward from the centre so the eye lands on the lit tile
    /// first. Total settle stays under half a second.
    private func entranceDelay(for index: Int) -> Double {
        let row = index / 3
        let column = index % 3
        let distance = abs(row - 1) + abs(column - 1)
        return Double(distance) * 0.06
    }
}

//
//  TrackpadView.swift
//  MirageControliOS
//

import QuartzCore
import SwiftUI
import UIKit

struct TrackpadView: View {
    let sender: TrackpadSender
    let colorScheme: ColorScheme

    @State private var sensitivity: Float = 1.8
    @State private var scrollMode: Bool = false
    @State private var activeGesture: TrackpadGestureKind?
    @State private var ripplePos: CGPoint?
    @State private var rippleVisible = false

    private var bg: Color {
        colorScheme == .dark ? Color(hex: "0A0A0F") : Color(UIColor.systemGroupedBackground)
    }
    private var surfaceFill: Color {
        colorScheme == .dark ? .white.opacity(0.06) : Color(UIColor.systemBackground)
    }
    private var surfaceShadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.3) : .black.opacity(0.07)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Trackpad surface ──────────────────────────────────────
            ZStack {
                // Background glass
                RoundedRectangle(cornerRadius: 28)
                    .fill(surfaceFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28)
                            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                    )
                    .shadow(color: surfaceShadowColor, radius: 16, y: 8)

                // Multi-touch surface — replaces the old DragGesture
                MultiTouchTrackpad(
                    callbacks: TrackpadCallbacks(
                        onCursorDelta: { dx, dy in
                            Task { await sender.sendMouseDelta(dx: dx, dy: dy) }
                        },
                        onScrollDelta: { dx, dy in
                            Task { await sender.sendScroll(dx: dx, dy: dy) }
                        },
                        onThreeFingerSwipe: { direction in
                            Task { await sender.sendThreeFingerSwipe(direction) }
                        },
                        onTap: { pos in
                            Task { await sender.sendClick(.left) }
                            triggerRipple(at: pos)
                        },
                        onDoubleTap: { pos in
                            Task { await sender.sendDoubleClick(.left) }
                            triggerRipple(at: pos)
                        },
                        onLongPress: { pos in
                            Task { await sender.sendClick(.right) }
                            triggerRipple(at: pos)
                        },
                        onGestureChanged: { gesture in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                activeGesture = gesture
                            }
                        }
                    ),
                    sensitivity: sensitivity,
                    scrollMode: scrollMode
                )
                .clipShape(RoundedRectangle(cornerRadius: 28))

                // ── Gesture indicator (top-left corner) ──────────────
                VStack {
                    HStack {
                        if let gesture = activeGesture {
                            GestureIndicator(gesture: gesture, colorScheme: colorScheme)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                        Spacer()

                        // Mode hint label
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(scrollMode ? "Scroll Mode" : "Trackpad")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.secondary.opacity(0.7))
                            Text("Tap • Left  |  Hold • Right  |  2F • Scroll  |  3F • Spaces")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.secondary.opacity(0.45))
                        }
                        .padding(12)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)

                // ── Ripple effect on tap ──────────────────────────────
                if let pos = ripplePos, rippleVisible {
                    Circle()
                        .fill(Color(hex: "6C63FF").opacity(0.35))
                        .frame(width: 60, height: 60)
                        .scaleEffect(rippleVisible ? 2.0 : 0.5)
                        .opacity(rippleVisible ? 0 : 1)
                        .position(pos)
                        .allowsHitTesting(false)
                        .onAppear {
                            withAnimation(.easeOut(duration: 0.4)) {
                                rippleVisible = false
                            }
                        }
                }

                // Finger guide dots (decoration)
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<3) { _ in
                            Circle()
                                .fill(Color.primary.opacity(0.1))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // ── Sensitivity slider ────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "tortoise")
                    .foregroundStyle(Color.secondary)
                    .font(.system(size: 12))
                Slider(value: $sensitivity, in: 0.5...4.0)
                    .tint(Color.primary.opacity(0.6))
                Image(systemName: "hare")
                    .foregroundStyle(Color.secondary)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            // ── Gesture button bar ────────────────────────────────────
            GestureButtonBar(sender: sender, scrollMode: $scrollMode, colorScheme: colorScheme)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 16)
        }
        .background(bg)
    }

    // MARK: - Ripple

    private func triggerRipple(at pos: CGPoint) {
        rippleVisible = false
        ripplePos = pos
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            rippleVisible = true
        }
    }
}

// MARK: - Gesture Indicator Overlay

private struct GestureIndicator: View {
    let gesture: TrackpadGestureKind
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.06))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        )
        .padding(12)
    }

    private var iconName: String {
        switch gesture {
        case .cursor: "hand.point.up.left"
        case .scroll: "arrow.up.and.down"
        case .threeFingerSwipe(let dir):
            switch dir {
            case .left:  "arrow.left"
            case .right: "arrow.right"
            case .up:    "arrow.up"
            case .down:  "arrow.down"
            }
        }
    }

    private var label: String {
        switch gesture {
        case .cursor: "Cursor"
        case .scroll: "Scrolling"
        case .threeFingerSwipe(let dir):
            switch dir {
            case .left, .right: "Spaces"
            case .up:           "Mission Control"
            case .down:         "App Exposé"
            }
        }
    }

    private var iconColor: Color {
        switch gesture {
        case .cursor: Color(hex: "6C63FF")
        case .scroll: Color(hex: "10B981")
        case .threeFingerSwipe: Color(hex: "38BDF8")
        }
    }
}

// MARK: - Gesture Button Bar

struct GestureButtonBar: View {
    let sender: TrackpadSender
    @Binding var scrollMode: Bool
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 0) {
            // Scroll mode toggle — highlighted when active
            ScrollToggleButton(isActive: $scrollMode, colorScheme: colorScheme)

            GestureButton(label: "Left Click",   icon: "cursorarrow.click",              color: Color(hex: "6C63FF"), haptic: .medium, colorScheme: colorScheme) {
                Task { await sender.sendClick(.left) }
            }
            GestureButton(label: "Right Click",  icon: "cursorarrow.click.2",            color: Color(hex: "A78BFA"), haptic: .heavy,  colorScheme: colorScheme) {
                Task { await sender.sendClick(.right) }
            }
            GestureButton(label: "Double Click", icon: "cursorarrow.click.badge.clock",  color: Color(hex: "818CF8"), haptic: .double, colorScheme: colorScheme) {
                Task { await sender.sendDoubleClick(.left) }
            }
            GestureButton(label: "Mission", icon: "macwindow.on.rectangle", color: Color(hex: "38BDF8"), haptic: .light, colorScheme: colorScheme) {
                Task { await sender.sendMacro("missioncontrol_trigger") }
            }
            GestureButton(label: "Desktop", icon: "menubar.rectangle",       color: Color(hex: "34D399"), haptic: .light, colorScheme: colorScheme) {
                Task { await sender.sendShortcut(["fn", "f11"]) }
            }
        }
    }
}

/// Dedicated scroll toggle with active state highlight.
private struct ScrollToggleButton: View {
    @Binding var isActive: Bool
    let colorScheme: ColorScheme

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isActive.toggle()
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: isActive ? "scroll.fill" : "scroll")
                    .font(.system(size: 28, weight: .thin))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isActive ? Color(hex: "10B981") : Color(hex: "10B981").opacity(0.6))
                    .frame(height: 34)
                Text("Scroll")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(isActive ? Color(hex: "10B981") : Color.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isActive ? Color(hex: "10B981").opacity(colorScheme == .dark ? 0.15 : 0.1) : Color.clear)
            )
            .scaleEffect(isActive ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Haptic style

enum GestureHaptic {
    case light, medium, heavy, double, selection

    @MainActor
    func trigger() {
        switch self {
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .double:
            let g = UIImpactFeedbackGenerator(style: .medium)
            g.impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { g.impactOccurred() }
        }
    }
}

// MARK: - Gesture Button

struct GestureButton: View {
    let label: String
    let icon: String
    let color: Color
    var haptic: GestureHaptic = .medium
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: {
            haptic.trigger()
            action()
        }) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .thin))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isPressed ? color : color.opacity(0.8))
                    .frame(height: 34)
                Text(label)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary.opacity(isPressed ? 1.0 : 0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isPressed ? color.opacity(colorScheme == .dark ? 0.15 : 0.1) : Color.clear)
                    .animation(.easeOut(duration: 0.12), value: isPressed)
            )
            .scaleEffect(isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}

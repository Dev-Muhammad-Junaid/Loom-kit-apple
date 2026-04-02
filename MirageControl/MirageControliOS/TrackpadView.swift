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

    @State private var scrollMode = false
    @State private var lastDragLocation: CGPoint?
    @State private var sensitivity: Float = 1.8
    @State private var ripplePos: CGPoint?
    @State private var rippleVisible = false

    // Custom Gesture State — CACurrentMediaTime for monotonic precision
    @State private var touchStartTime: Double = 0
    @State private var touchStartLocation: CGPoint?
    @State private var longPressTask: Task<Void, Never>?
    @State private var lastTapTime: Double = 0

    // Pre-allocated haptic generators — eliminates ~10ms alloc latency per tap
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)

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

                // Mode label
                VStack {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(scrollMode ? "Scroll Mode" : "Trackpad")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.secondary.opacity(0.7))
                            
                            Text("Tap • Left  |  Long Press • Right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                        }
                        .padding(12)
                    }
                    Spacer()
                }

                // Ripple effect on tap
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDragChange(value)
                    }
                    .onEnded { value in
                        handleDragEnded(value)
                    }
            )
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

    // MARK: - Drag handling

    private func handleDragChange(_ value: DragGesture.Value) {
        let current = value.location

        // Detect new touch boundary
        if touchStartTime == 0 {
            touchStartTime = CACurrentMediaTime()
            touchStartLocation = current
            // Prepare haptics ahead of time for zero-latency feedback
            mediumHaptic.prepare()
            heavyHaptic.prepare()

            // Schedule long press right click evaluation
            longPressTask?.cancel()
            longPressTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                // Reached time threshold without large movement
                await sender.sendClick(.right)

                await MainActor.run {
                    heavyHaptic.impactOccurred()
                    triggerRipple(at: current)
                }
            }
        }

        // Evaluate drift distance to invalidate stationary taps/holds
        if let startLoc = touchStartLocation {
            let distance = hypot(current.x - startLoc.x, current.y - startLoc.y)
            if distance > 6 {
                // User is firmly dragging, cancel tap/hold interpretation
                longPressTask?.cancel()
                touchStartLocation = nil
            }
        }

        // Standard delta math for network
        guard let last = lastDragLocation else {
            lastDragLocation = current
            return
        }
        let dx = Float(current.x - last.x)
        let dy = Float(current.y - last.y)
        lastDragLocation = current

        Task {
            if scrollMode {
                await sender.sendScroll(dx: dx * 0.5, dy: dy * 0.5)
            } else {
                await sender.sendMouseDelta(dx: dx * sensitivity, dy: dy * sensitivity)
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        lastDragLocation = nil
        longPressTask?.cancel()

        if touchStartTime > 0, let startLoc = touchStartLocation {
            let duration = CACurrentMediaTime() - touchStartTime
            // If released extremely fast without moving past the 6pt radius deadzone
            if duration < 0.3 {
                let now = CACurrentMediaTime()
                if lastTapTime > 0, (now - lastTapTime) < 0.35 {
                    // Double Tap — two quick medium impacts
                    Task { await sender.sendDoubleClick(.left) }
                    triggerRipple(at: startLoc)
                    lastTapTime = 0
                    mediumHaptic.impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        mediumHaptic.impactOccurred()
                    }
                } else {
                    // Single Tap — medium impact
                    Task { await sender.sendClick(.left) }
                    lastTapTime = now
                    mediumHaptic.impactOccurred()
                }
            }
        }

        touchStartTime = 0
        touchStartLocation = nil
    }

    private func triggerRipple(at pos: CGPoint) {
        // Reset state so the circle reappears small/opaque,
        // then onAppear drives the expand-and-fade animation.
        rippleVisible = false
        ripplePos = pos
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            rippleVisible = true
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
            GestureButton(label: "Left Click",   icon: "cursorarrow.click",              color: Color(hex: "6C63FF"), haptic: .medium, colorScheme: colorScheme) {
                Task { await sender.sendClick(.left) }
            }
            GestureButton(label: "Right Click",  icon: "cursorarrow.click.2",            color: Color(hex: "A78BFA"), haptic: .heavy,  colorScheme: colorScheme) {
                Task { await sender.sendClick(.right) }
            }
            GestureButton(label: "Double Click", icon: "cursorarrow.click.badge.clock",  color: Color(hex: "818CF8"), haptic: .double, colorScheme: colorScheme) {
                Task { await sender.sendDoubleClick(.left) }
            }
            GestureButton(
                label: scrollMode ? "Scroll On" : "Scroll",
                icon:  scrollMode ? "arrow.up.and.down.and.sparkles" : "arrow.up.and.down",
                color: scrollMode ? Color(hex: "10B981") : Color.secondary,
                haptic: .selection,
                colorScheme: colorScheme
            ) {
                scrollMode.toggle()
            }
            GestureButton(label: "Mission", icon: "macwindow.on.rectangle", color: Color(hex: "38BDF8"), haptic: .light, colorScheme: colorScheme) {
                Task { await sender.sendShortcut(["ctrl", "up"]) }
            }
            GestureButton(label: "Desktop", icon: "menubar.rectangle",       color: Color(hex: "34D399"), haptic: .light, colorScheme: colorScheme) {
                Task { await sender.sendShortcut(["fn", "f11"]) }
            }
        }
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




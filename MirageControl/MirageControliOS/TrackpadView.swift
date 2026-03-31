//
//  TrackpadView.swift
//  MirageControliOS
//

import SwiftUI
import UIKit

struct TrackpadView: View {
    let sender: TrackpadSender

    @State private var scrollMode = false
    @State private var lastDragLocation: CGPoint?
    @State private var sensitivity: Float = 1.8
    @State private var ripplePos: CGPoint?
    @State private var rippleVisible = false
    
    // Custom Gesture State
    @State private var touchStartTime: Date?
    @State private var touchStartLocation: CGPoint?
    @State private var longPressTask: Task<Void, Never>?
    @State private var lastTapTime: Date?

    var body: some View {
        VStack(spacing: 0) {
            // ── Trackpad surface ──────────────────────────────────────
            ZStack {
                // Background glass
                RoundedRectangle(cornerRadius: 28)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.3), .white.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

                // Mode label
                VStack {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(scrollMode ? "Scroll Mode" : "Trackpad")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.45))
                            
                            Text("Tap • Left  |  Long Press • Right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.25))
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
                        .animation(.easeOut(duration: 0.4), value: rippleVisible)
                }

                // Finger guide dots (decoration)
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<3) { _ in
                            Circle()
                                .fill(.white.opacity(0.12))
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
                    .foregroundStyle(.white.opacity(0.5))
                    .font(.system(size: 12))
                Slider(value: $sensitivity, in: 0.5...4.0)
                    .tint(Color(hex: "6C63FF"))
                Image(systemName: "hare")
                    .foregroundStyle(.white.opacity(0.5))
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            // ── Gesture button bar ────────────────────────────────────
            GestureButtonBar(sender: sender, scrollMode: $scrollMode)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 16)
        }
        .background(
            LinearGradient(
                colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Drag handling

    private func handleDragChange(_ value: DragGesture.Value) {
        let current = value.location

        // Detect new touch boundary
        if touchStartTime == nil {
            touchStartTime = Date()
            touchStartLocation = current
            
            // Schedule long press right click evaluation
            longPressTask?.cancel()
            longPressTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                // Reached time threshold without large movement
                await sender.sendClick(.right)
                
                await MainActor.run {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
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
        
        if let startTime = touchStartTime, let startLoc = touchStartLocation {
            let duration = Date().timeIntervalSince(startTime)
            // If released extremely fast without moving past the 6pt radius deadzone
            if duration < 0.3 {
                let now = Date()
                if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < 0.35 {
                    // Double Tap
                    Task { await sender.sendDoubleClick(.left) }
                    triggerRipple(at: startLoc)
                    lastTapTime = nil // reset chain
                } else {
                    // Single Tap
                    Task { await sender.sendClick(.left) }
                    lastTapTime = now
                }
            }
        }
        
        touchStartTime = nil
        touchStartLocation = nil
    }

    private func triggerRipple(at pos: CGPoint) {
        ripplePos = pos
        rippleVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            rippleVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                rippleVisible = false
            }
        }
    }
}

// MARK: - Gesture Button Bar

struct GestureButtonBar: View {
    let sender: TrackpadSender
    @Binding var scrollMode: Bool

    var body: some View {
        HStack(spacing: 10) {
            GestureButton(label: "Left", icon: "hand.point.left.fill", color: Color(hex: "6C63FF")) {
                Task { await sender.sendClick(.left) }
            }
            GestureButton(label: "Right", icon: "hand.point.right.fill", color: Color(hex: "7C3AED")) {
                Task { await sender.sendClick(.right) }
            }
            GestureButton(label: "Double", icon: "hand.tap.fill", color: Color(hex: "6D28D9")) {
                Task { await sender.sendDoubleClick(.left) }
            }
            GestureButton(
                label: scrollMode ? "Scroll ✓" : "Scroll",
                icon: scrollMode ? "scroll.fill" : "scroll",
                color: scrollMode ? Color(hex: "10B981") : Color(hex: "374151")
            ) {
                scrollMode.toggle()
            }
            GestureButton(label: "Mission", icon: "square.grid.2x2", color: Color(hex: "1D4ED8")) {
                Task { await sender.sendShortcut(["ctrl", "up"]) }
            }
            GestureButton(label: "Desktop", icon: "desktopcomputer", color: Color(hex: "0F766E")) {
                Task { await sender.sendShortcut(["fn", "f11"]) }
            }
        }
    }
}

// MARK: - Gesture Button

struct GestureButton: View {
    let label: String
    let icon: String
    let color: Color
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(color.opacity(isPressed ? 0.9 : 0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.93 : 1.0)
            .animation(.spring(duration: 0.18), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}




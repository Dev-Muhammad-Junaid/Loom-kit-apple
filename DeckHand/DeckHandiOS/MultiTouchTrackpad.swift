//
//  MultiTouchTrackpad.swift
//  DeckHandiOS
//
//  UIViewRepresentable that wraps a custom UIView for raw multi-touch
//  tracking.  SwiftUI's DragGesture only tracks one finger — this gives
//  us 1/2/3 finger awareness for cursor, scroll, and Spaces gestures.
//

import QuartzCore
import SwiftUI
import UIKit

// MARK: - Gesture event types reported to the parent view

enum TrackpadGestureKind: Equatable {
    case cursor           // 1-finger drag
    case scroll           // 2-finger drag
    case threeFingerSwipe(ThreeFingerDirection)

    enum ThreeFingerDirection: String {
        case left, right, up, down
    }
}

/// Callbacks from the multi-touch surface to the SwiftUI host.
struct TrackpadCallbacks {
    /// Continuous delta during 1-finger drag.
    var onCursorDelta: (Float, Float) -> Void = { _, _ in }
    /// Continuous delta during 2-finger drag (scroll).
    var onScrollDelta: (Float, Float) -> Void = { _, _ in }
    /// Fired once all fingers driving an active scroll gesture lift, so
    /// the host can ship `ScrollPhase.end` to the Mac. Required for AppKit's
    /// rubber-banding + momentum animations to play out instead of just
    /// stopping abruptly.
    var onScrollEnded: () -> Void = { }
    /// Fired once when a 3-finger directional swipe is recognized.
    var onThreeFingerSwipe: (TrackpadGestureKind.ThreeFingerDirection) -> Void = { _ in }
    /// 1-finger tap (fast touch < 0.3s with < 6pt movement).
    var onTap: (CGPoint) -> Void = { _ in }
    /// 1-finger double-tap (two taps within 0.35s).
    var onDoubleTap: (CGPoint) -> Void = { _ in }
    /// 1-finger long press (> 0.4s stationary).
    var onLongPress: (CGPoint) -> Void = { _ in }
    /// Reports the active gesture kind for the UI indicator (nil = idle).
    var onGestureChanged: (TrackpadGestureKind?) -> Void = { _ in }
}

// MARK: - SwiftUI bridge

struct MultiTouchTrackpad: UIViewRepresentable {
    let callbacks: TrackpadCallbacks
    let sensitivity: Float
    let scrollMode: Bool
    var naturalScrolling: Bool = false

    func makeUIView(context: Context) -> TouchTrackingView {
        let view = TouchTrackingView()
        apply(to: view)
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: TouchTrackingView) {
        view.callbacks = callbacks
        view.sensitivity = sensitivity
        view.scrollMode = scrollMode
        view.naturalScrolling = naturalScrolling
    }
}

// MARK: - Raw touch-tracking UIView

final class TouchTrackingView: UIView {
    var callbacks = TrackpadCallbacks()
    var sensitivity: Float = 1.8
    var scrollMode: Bool = false
    /// Flips scroll deltas so the content tracks the fingers.
    var naturalScrolling: Bool = false

    private var scrollSign: Float { naturalScrolling ? -1 : 1 }

    // ── Touch tracking state ──────────────────────────────────────
    private var activeTouches: [UITouch] = []
    private var lastCentroid: CGPoint?

    // ── Tap / long-press detection ────────────────────────────────
    private var touchDownTime: Double = 0
    private var touchDownLocation: CGPoint = .zero
    private var longPressTimer: Task<Void, Never>?
    private var lastSingleTapTime: Double = 0
    private var hasMoved = false
    private var longPressFired = false  // prevents tap after long-press right-click

    // ── 3-finger swipe detection ──────────────────────────────────
    private var threeFingerOrigin: CGPoint?
    private var threeFingerFired = false

    /// `true` while a scroll gesture (1-finger scrollMode or 2-finger drag)
    /// is in flight. Drives `onScrollEnded` so the host can ship a phased
    /// `.end` event when the driving fingers lift.
    private var scrollActive = false


    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for touch in touches {
            if !activeTouches.contains(touch) {
                activeTouches.append(touch)
            }
        }

        let count = activeTouches.count
        lastCentroid = centroid(of: activeTouches)

        if count == 1 {
            // Start tap/long-press detection
            let loc = activeTouches[0].location(in: self)
            touchDownTime = CACurrentMediaTime()
            touchDownLocation = loc
            hasMoved = false
            longPressFired = false


            // Schedule long press (right-click). Re-validate touch state after
            // the sleep so a second finger landing within the 400 ms window
            // (or the user dragging past the dead zone) doesn't race against
            // the timer and synthesize a phantom right-click.
            longPressTimer?.cancel()
            longPressTimer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled,
                      self.activeTouches.count == 1,
                      !self.hasMoved
                else { return }
                self.longPressFired = true
                GestureHaptic.heavy.trigger()
                self.callbacks.onLongPress(loc)
            }
        } else {
            // Multi-finger → cancel tap/long-press
            longPressTimer?.cancel()
            hasMoved = true
        }

        if count == 3 {
            threeFingerOrigin = centroid(of: activeTouches)
            threeFingerFired = false
        }

        // Report gesture kind
        callbacks.onGestureChanged(gestureKind(for: count))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)

        let count = activeTouches.count
        let currentCentroid = centroid(of: activeTouches)

        guard let last = lastCentroid else {
            lastCentroid = currentCentroid
            return
        }

        let dx = Float(currentCentroid.x - last.x)
        let dy = Float(currentCentroid.y - last.y)
        lastCentroid = currentCentroid

        // Check if moved beyond dead zone (for tap detection)
        if count == 1 {
            let dist = hypot(currentCentroid.x - touchDownLocation.x,
                             currentCentroid.y - touchDownLocation.y)
            if dist > 6 {
                hasMoved = true
                longPressTimer?.cancel()
            }
        }

        switch count {
        case 1:
            // 1-finger: cursor OR scroll depending on mode
            if hasMoved {
                if scrollMode {
                    scrollActive = true
                    callbacks.onScrollDelta(dx * 0.5 * scrollSign, dy * 0.5 * scrollSign)
                    callbacks.onGestureChanged(.scroll)
                } else {
                    callbacks.onCursorDelta(dx * sensitivity, dy * sensitivity)
                    callbacks.onGestureChanged(.cursor)
                }
            }

        case 2:
            // Scroll — gentler multiplier
            scrollActive = true
            callbacks.onScrollDelta(dx * 0.5 * scrollSign, dy * 0.5 * scrollSign)
            callbacks.onGestureChanged(.scroll)

        case 3:
            // Detect swipe direction once past threshold
            if !threeFingerFired, let origin = threeFingerOrigin {
                let totalDx = currentCentroid.x - origin.x
                let totalDy = currentCentroid.y - origin.y
                let threshold: CGFloat = 60

                if abs(totalDx) > threshold || abs(totalDy) > threshold {
                    let direction: TrackpadGestureKind.ThreeFingerDirection
                    if abs(totalDx) > abs(totalDy) {
                        direction = totalDx > 0 ? .right : .left
                    } else {
                        direction = totalDy > 0 ? .down : .up
                    }
                    threeFingerFired = true
                    GestureHaptic.medium.trigger()
                    callbacks.onThreeFingerSwipe(direction)
                    callbacks.onGestureChanged(.threeFingerSwipe(direction))
                }
            }

        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)

        let wasCount = activeTouches.count
        activeTouches.removeAll { touches.contains($0) }

        // All fingers lifted — evaluate final gesture
        if activeTouches.isEmpty {
            longPressTimer?.cancel()

            // If a scroll gesture was in flight, surface the `.end` phase to
            // the host before resetting state. AppKit's scroll views need
            // this transition to drive their rubber-banding back to rest.
            if scrollActive {
                scrollActive = false
                callbacks.onScrollEnded()
            }

            // 1-finger tap detection — only if long press didn't already fire
            if wasCount == 1 && !hasMoved && !longPressFired {
                let duration = CACurrentMediaTime() - touchDownTime
                if duration < 0.3 {
                    let now = CACurrentMediaTime()
                    if lastSingleTapTime > 0 && (now - lastSingleTapTime) < 0.35 {
                        // Double-tap
                        lastSingleTapTime = 0
                        GestureHaptic.medium.trigger()
                        callbacks.onDoubleTap(touchDownLocation)
                    } else {
                        // Single tap
                        lastSingleTapTime = now
                        GestureHaptic.medium.trigger()
                        callbacks.onTap(touchDownLocation)
                    }
                }
            }

            // Reset state
            lastCentroid = nil
            threeFingerOrigin = nil
            threeFingerFired = false
            longPressFired = false
            callbacks.onGestureChanged(nil)
        } else {
            // Some fingers still down — update centroid
            lastCentroid = centroid(of: activeTouches)
            callbacks.onGestureChanged(gestureKind(for: activeTouches.count))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        activeTouches.removeAll { touches.contains($0) }
        if activeTouches.isEmpty {
            longPressTimer?.cancel()
            if scrollActive {
                scrollActive = false
                callbacks.onScrollEnded()
            }
            lastCentroid = nil
            threeFingerOrigin = nil
            threeFingerFired = false
            callbacks.onGestureChanged(nil)
        }
    }

    // MARK: - Helpers

    private func centroid(of touches: [UITouch]) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for touch in touches {
            let loc = touch.location(in: self)
            sumX += loc.x
            sumY += loc.y
        }
        let n = CGFloat(touches.count)
        return CGPoint(x: sumX / n, y: sumY / n)
    }

    private func gestureKind(for fingerCount: Int) -> TrackpadGestureKind? {
        switch fingerCount {
        case 1:  return scrollMode ? .scroll : .cursor
        case 2:  return .scroll
        case 3:  return nil  // Reported on swipe detection
        default: return nil
        }
    }
}

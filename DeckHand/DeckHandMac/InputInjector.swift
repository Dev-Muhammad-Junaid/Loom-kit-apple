//
//  InputInjector.swift
//  DeckHandMac
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

// These constants are defined in IOKit/hidsystem/ev_keymap.h but aren't
// globally visible without importing IOKit.hid.
let NX_KEYTYPE_PLAY: Int32 = 16
let NX_KEYTYPE_NEXT: Int32 = 17
let NX_KEYTYPE_PREVIOUS: Int32 = 18

/// Injects mouse and keyboard events into the macOS input system via CGEvent.
/// Requires Accessibility access — call `requestAccessibility()` on first use.
@MainActor
final class InputInjector {
    static let shared = InputInjector()

    private init() {}

    // MARK: - Diagnostics
    //
    // Every injection method below returns silently when Accessibility
    // isn't granted, which made "the Mac received the message but the
    // cursor never moved" indistinguishable from "the message never
    // arrived" (hypothesis 3). These throttled logs make that distinction
    // visible in Console.app / `log stream` without flooding at 120 Hz.
    private var lastSkipLogAt: Date = .distantPast
    private var hasLoggedFirstInjection = false
    /// Timestamp of the previous `moveCursor` injection, used to detect
    /// dropped frames during active movement (cursor-jitter investigation).
    private var lastMoveCursorAt: Date?

    /// Logs (≤1/sec) that an inbound input event was dropped because
    /// Accessibility isn't granted — the smoking gun for "received but
    /// not injected."
    private func noteInjectSkipped(_ action: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSkipLogAt) > 1 else { return }
        lastSkipLogAt = now
        DeckHandLog.input.error("⛔️ \(action, privacy: .public) skipped — Accessibility not granted (AXIsProcessTrusted=false)")
    }

    /// One-shot confirmation that CGEvents are actually being posted, so a
    /// successful "received and injected" path is provable from the logs.
    private func noteInjectionActive(_ action: String) {
        guard !hasLoggedFirstInjection else { return }
        hasLoggedFirstInjection = true
        DeckHandLog.input.info("✅ Injecting input — first \(action, privacy: .public) posted since launch (Accessibility granted)")
    }

    // MARK: - Accessibility

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    nonisolated func requestAccessibility() {
        // Use the known string key directly to avoid the global shared-mutable warning
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Mouse movement

    /// Moves the cursor by a relative delta (in points).
    ///
    /// The iPad applies user-chosen sensitivity before sending; the host
    /// adds a subtle acceleration curve so small movements stay precise
    /// while large swipes cover more distance — matching macOS trackpad feel.
    ///
    /// We let macOS handle every aspect of multi-display routing. No local
    /// clamping, no synthetic delta fields — just a clean absolute-position
    /// `mouseMoved` event. macOS clips out-of-bounds coordinates at the HID
    /// layer on its own, so the cursor moves freely across every connected
    /// display without us doing anything extra.
    func moveCursor(dx: Float, dy: Float) {
        guard isAccessibilityGranted else { noteInjectSkipped("mouseDelta"); return }
        // Jitter probe: during active movement the iPad streams deltas at up to
        // 120 Hz (~8 ms apart). A gap in the 33–250 ms band means frames were
        // dropped while the user was still moving — i.e. visible cursor jitter,
        // usually from main-thread contention. Idle gaps (>250 ms, finger
        // lifted) are normal and not logged, so this stays quiet in steady use.
        let now = Date()
        if let last = lastMoveCursorAt {
            let gapMs = now.timeIntervalSince(last) * 1000
            if gapMs > 33, gapMs < 250 {
                DeckHandLog.input.info("Cursor delta gap \(Int(gapMs))ms — possible jitter / main-thread contention")
            }
        }
        lastMoveCursorAt = now
        let currentPos = NSEvent.mouseLocation
        // NSEvent y is flipped relative to CGDisplayBounds. We flip using
        // the *global* frame's max-y so the conversion stays correct on
        // multi-display setups where the main display isn't at the top.
        let cgCurrent = Self.flipNSPointToCG(currentPos)

        let accelDx = applyAcceleration(dx)
        let accelDy = applyAcceleration(dy)

        let next = CGPoint(x: cgCurrent.x + Double(accelDx),
                           y: cgCurrent.y + Double(accelDy))
        let event = CGEvent(mouseEventSource: nil,
                            mouseType: .mouseMoved,
                            mouseCursorPosition: next,
                            mouseButton: .left)
        event?.post(tap: .cghidEventTap)
        noteInjectionActive("mouseDelta")
    }

    /// macOS-style pointer acceleration: small deltas stay 1:1,
    /// large swipes ramp up for fast traversal.
    private func applyAcceleration(_ delta: Float) -> Float {
        let magnitude = abs(delta)
        // Below 3pt of movement, keep 1:1 for precision work.
        // Above that, gently ramp up to feel natural on large screens.
        let factor: Float = magnitude < 3 ? 1.0 : 1.0 + (magnitude - 3) * 0.12
        return delta * factor
    }

    // MARK: - Scroll

    func scroll(dx: Float, dy: Float) {
        scroll(dx: dx, dy: dy, phase: .changed)
    }

    /// Scroll-phase-aware send so AppKit / WebKit / SwiftUI scroll views
    /// see continuous scroll gestures rather than a stream of un-phased
    /// wheel ticks. The iPad uses this for the begin/end transitions; the
    /// trackpad's "natural" rubber-banding and momentum continuation only
    /// kicks in when these phases are present.
    func scroll(dx: Float, dy: Float, phase: ScrollPhase) {
        guard isAccessibilityGranted else { noteInjectSkipped("scroll"); return }
        // scrollWheel: unit=pixel, axis1=vertical, axis2=horizontal
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-dy * 3),
            wheel2: Int32(-dx * 3),
            wheel3: 0
        ) else { return }

        // Continuous scroll bit must be set so AppKit treats the deltas as
        // pixel-precise (trackpad style), not line-step (mouse-wheel style).
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)

        switch phase {
        case .begin:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)   // kCGScrollPhaseBegan
        case .changed:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)   // kCGScrollPhaseChanged
        case .end:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)   // kCGScrollPhaseEnded
        case .momentumBegin:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1) // kCGMomentumScrollPhaseBegin
        case .momentumChanged:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2) // kCGMomentumScrollPhaseContinue
        case .momentumEnd:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3) // kCGMomentumScrollPhaseEnd
        }

        event.post(tap: .cghidEventTap)
    }

    /// Phases recognized by `scroll(dx:dy:phase:)`. Mirrors AppKit's
    /// `NSEvent.Phase` / momentum phases without dragging in AppKit types.
    enum ScrollPhase: Sendable {
        case begin
        case changed
        case end
        case momentumBegin
        case momentumChanged
        case momentumEnd
    }

    // MARK: - Clicks

    func click(button: MouseButton, double: Bool = false) {
        guard isAccessibilityGranted else { noteInjectSkipped("click"); return }
        let pos = currentCGCursorPosition()
        let (downType, upType, cgBtn) = cgMouseTypes(for: button)

        // macOS double-click convention: the *first* down/up pair has
        // clickState = 1, the *second* has clickState = 2. Firing two pairs
        // both with clickState = 2 is read as a triple-click by AppKit.
        let states: [Int64] = double ? [1, 2] : [1]
        for state in states {
            let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                               mouseCursorPosition: pos, mouseButton: cgBtn)
            down?.setIntegerValueField(.mouseEventClickState, value: state)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                             mouseCursorPosition: pos, mouseButton: cgBtn)
            up?.setIntegerValueField(.mouseEventClickState, value: state)
            up?.post(tap: .cghidEventTap)
        }
        noteInjectionActive("click")
    }

    // MARK: - Keyboard shortcuts

    /// Sends a keyboard shortcut specified as an array of key name strings.
    /// Example: ["cmd", "space"], ["cmd", "shift", "3"]
    ///
    /// Uses `.combinedSessionState` so the synthesized modifiers aren't
    /// overridden by whatever modifier keys the user happens to be holding on
    /// a physical keyboard. Posts modifier flag-changes as separate events
    /// around the key event; some apps (Chrome, Electron apps, Cursor) drop
    /// shortcuts when modifier flags arrive only as side-channel `flags` on
    /// the keydown — they want to see real `flagsChanged` events.
    func sendShortcut(keys: [String]) {
        guard isAccessibilityGranted else { noteInjectSkipped("shortcut"); return }
        let (modifiers, keyCode) = parseKeys(keys)
        guard let kc = keyCode else {
            #if DEBUG
            print("Deck Hand: ⚠️ Unknown shortcut key in \(keys)")
            #endif
            return
        }

        let src = CGEventSource(stateID: .combinedSessionState)

        // 1. Press each modifier as a real flagsChanged event.
        let mods = activeModifierKeys(modifiers)
        for modKey in mods {
            if let down = CGEvent(keyboardEventSource: src, virtualKey: modKey, keyDown: true) {
                down.flags = modifiers
                down.post(tap: .cghidEventTap)
            }
        }

        // 2. Press and release the non-modifier key with full flags attached.
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true) {
            keyDown.flags = modifiers
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false) {
            keyUp.flags = modifiers
            keyUp.post(tap: .cghidEventTap)
        }

        // 3. Release modifiers in reverse order.
        for modKey in mods.reversed() {
            if let up = CGEvent(keyboardEventSource: src, virtualKey: modKey, keyDown: false) {
                up.flags = []
                up.post(tap: .cghidEventTap)
            }
        }
        noteInjectionActive("shortcut")
    }

    /// Maps a `CGEventFlags` set to the virtual key codes we need to press so
    /// AppKit sees `flagsChanged` events for each modifier.
    private func activeModifierKeys(_ flags: CGEventFlags) -> [CGKeyCode] {
        var keys: [CGKeyCode] = []
        if flags.contains(.maskCommand)     { keys.append(0x37) } // left cmd
        if flags.contains(.maskShift)       { keys.append(0x38) } // left shift
        if flags.contains(.maskAlternate)   { keys.append(0x3A) } // left option
        if flags.contains(.maskControl)     { keys.append(0x3B) } // left control
        if flags.contains(.maskSecondaryFn) { keys.append(0x3F) } // fn
        return keys
    }

    // MARK: - Media Controls

    /// Sends a system-defined media key (e.g., NX_KEYTYPE_PLAY).
    func sendMediaKey(_ keyType: Int32) {
        guard isAccessibilityGranted else { noteInjectSkipped("mediaKey"); return }

        // System defined key down
        if let down = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyType << 16) | (0xa << 8)),
            data2: -1
        ) {
            down.cgEvent?.post(tap: .cghidEventTap)
        }

        // System defined key up
        if let up = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyType << 16) | (0xb << 8)),
            data2: -1
        ) {
            up.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Helpers

    private func currentCGCursorPosition() -> CGPoint {
        Self.flipNSPointToCG(NSEvent.mouseLocation)
    }

    /// Converts an AppKit (origin-bottom-left, multi-screen-aware) point to
    /// a CGEvent (origin-top-left) point.
    private static func flipNSPointToCG(_ point: CGPoint) -> CGPoint {
        // Use the union of all displays so the conversion stays correct
        // regardless of which screen the cursor happens to be on.
        let unionMaxY = NSScreen.screens
            .map(\.frame.maxY)
            .max() ?? (NSScreen.main?.frame.maxY ?? 900)
        return CGPoint(x: point.x, y: unionMaxY - point.y)
    }

    private func cgMouseTypes(for button: MouseButton) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case .left:   return (.leftMouseDown, .leftMouseUp, .left)
        case .right:  return (.rightMouseDown, .rightMouseUp, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    /// Maps string key names → (CGEventFlags, CGKeyCode?)
    private func parseKeys(_ keys: [String]) -> (CGEventFlags, CGKeyCode?) {
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?

        for key in keys.map({ $0.lowercased() }) {
            switch key {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift":          flags.insert(.maskShift)
            case "option", "alt":  flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn":             flags.insert(.maskSecondaryFn)
            default:
                keyCode = keyCodeForName(key)
            }
        }
        return (flags, keyCode)
    }

    private func keyCodeForName(_ name: String) -> CGKeyCode? {
        // Common key mapping
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
            "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18,
            "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
            "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30,
            "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
            "space": 49, "return": 36, "enter": 36, "tab": 48,
            "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "up": 126, "down": 125, "left": 123, "right": 124,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118,
            "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        return map[name.lowercased()]
    }
}

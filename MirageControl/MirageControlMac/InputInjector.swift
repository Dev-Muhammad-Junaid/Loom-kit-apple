//
//  InputInjector.swift
//  MirageControlMac
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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

    /// Moves the cursor by a relative delta (in points). Scales by sensitivity.
    func moveCursor(dx: Float, dy: Float, sensitivity: Float = 1.5) {
        guard isAccessibilityGranted else { return }
        let currentPos = NSEvent.mouseLocation
        // NSEvent y is flipped relative to CGDisplayBounds
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let cgCurrent = CGPoint(x: currentPos.x,
                                y: screenHeight - currentPos.y)
        let next = CGPoint(x: cgCurrent.x + Double(dx * sensitivity),
                           y: cgCurrent.y + Double(dy * sensitivity))
        let clamped = clamp(next)
        let event = CGEvent(mouseEventSource: nil,
                            mouseType: .mouseMoved,
                            mouseCursorPosition: clamped,
                            mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll

    func scroll(dx: Float, dy: Float) {
        guard isAccessibilityGranted else { return }
        // scrollWheel: unit=pixel, axis1=vertical, axis2=horizontal
        let event = CGEvent(scrollWheelEvent2Source: nil,
                            units: .pixel,
                            wheelCount: 2,
                            wheel1: Int32(-dy * 3),
                            wheel2: Int32(-dx * 3),
                            wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Clicks

    func click(button: MouseButton, double: Bool = false) {
        guard isAccessibilityGranted else { return }
        let pos = currentCGCursorPosition()
        let (downType, upType, cgBtn) = cgMouseTypes(for: button)
        let clickCount = double ? 2 : 1

        for _ in 0..<clickCount {
            let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                               mouseCursorPosition: pos, mouseButton: cgBtn)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                             mouseCursorPosition: pos, mouseButton: cgBtn)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            up?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard shortcuts

    /// Sends a keyboard shortcut specified as an array of key name strings.
    /// Example: ["cmd", "space"], ["cmd", "shift", "3"]
    func sendShortcut(keys: [String]) {
        guard isAccessibilityGranted else { return }
        let (modifiers, keyCode) = parseKeys(keys)
        guard let kc = keyCode else { return }

        let src = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)
        keyDown?.flags = modifiers
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)
        keyUp?.flags = modifiers
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Media Controls

    /// Sends a system-defined media key (e.g., NX_KEYTYPE_PLAY).
    func sendMediaKey(_ keyType: Int32) {
        guard isAccessibilityGranted else { return }

        // System defined key down
        if let down = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [(keyType == NX_KEYTYPE_PLAY || keyType == NX_KEYTYPE_NEXT || keyType == NX_KEYTYPE_PREVIOUS) ? NSEvent.ModifierFlags(rawValue: 0) : .init()],
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
            modifierFlags: [(keyType == NX_KEYTYPE_PLAY || keyType == NX_KEYTYPE_NEXT || keyType == NX_KEYTYPE_PREVIOUS) ? NSEvent.ModifierFlags(rawValue: 0) : .init()],
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
        let pos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        return CGPoint(x: pos.x, y: screenHeight - pos.y)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let screen = CGDisplayBounds(CGMainDisplayID())
        let x = max(screen.minX, min(screen.maxX - 1, point.x))
        let y = max(screen.minY, min(screen.maxY - 1, point.y))
        return CGPoint(x: x, y: y)
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

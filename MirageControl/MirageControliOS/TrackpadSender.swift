//
//  TrackpadSender.swift
//  MirageControliOS
//

import Foundation
import LoomKit
import QuartzCore

/// Actor that owns the active connection handle and throttles outgoing control messages.
/// Tuned for buttery-smooth 120 Hz trackpad input on iPad Pro (ProMotion).
actor TrackpadSender {
    private let handle: LoomConnectionHandle

    // ── Timing ──────────────────────────────────────────────────────
    // 120 Hz matches iPad Pro's ProMotion refresh rate so no touch
    // data is thrown away.  On non-ProMotion iPads (60 Hz) this just
    // means the cap is never hit.
    private let minimumInterval: Double = 1.0 / 120.0

    // Independent timestamps so that continuous scrolling doesn't starve
    // mouse movement (and vice versa). Previously both streams shared
    // `lastSentAt`, which meant fast scroll input could delay cursor
    // updates by up to 8 ms per tick.
    private var lastMouseSentAt: Double = 0     // CACurrentMediaTime()
    private var lastScrollSentAt: Double = 0

    // ── Delta accumulator ───────────────────────────────────────────
    private var pendingDeltaX: Float = 0
    private var pendingDeltaY: Float = 0
    private var isSendScheduled: Bool = false

    // ── Scroll accumulator ──────────────────────────────────────────
    private var pendingScrollDX: Float = 0
    private var pendingScrollDY: Float = 0
    private var isScrollSendScheduled: Bool = false

    init(handle: LoomConnectionHandle) {
        self.handle = handle
    }

    // MARK: - Throttled mouse delta (120 Hz)

    func sendMouseDelta(dx: Float, dy: Float) async {
        pendingDeltaX += dx
        pendingDeltaY += dy

        let now = CACurrentMediaTime()
        let elapsed = now - lastMouseSentAt

        if elapsed >= minimumInterval {
            await flushMouseDelta()
        } else if !isSendScheduled {
            isSendScheduled = true
            let delay = minimumInterval - elapsed
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self.flushMouseDelta()
            }
        }
    }

    private func flushMouseDelta() async {
        isSendScheduled = false
        guard pendingDeltaX != 0 || pendingDeltaY != 0 else { return }

        let dx = pendingDeltaX
        let dy = pendingDeltaY
        pendingDeltaX = 0
        pendingDeltaY = 0
        lastMouseSentAt = CACurrentMediaTime()

        await send(.mouseDelta(dx: dx, dy: dy))
    }

    // MARK: - Throttled scroll (120 Hz)

    func sendScroll(dx: Float, dy: Float) async {
        pendingScrollDX += dx
        pendingScrollDY += dy

        let now = CACurrentMediaTime()
        let elapsed = now - lastScrollSentAt

        if elapsed >= minimumInterval {
            await flushScroll()
        } else if !isScrollSendScheduled {
            isScrollSendScheduled = true
            let delay = minimumInterval - elapsed
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self.flushScroll()
            }
        }
    }

    private func flushScroll() async {
        isScrollSendScheduled = false
        guard pendingScrollDX != 0 || pendingScrollDY != 0 else { return }

        let dx = pendingScrollDX
        let dy = pendingScrollDY
        pendingScrollDX = 0
        pendingScrollDY = 0
        lastScrollSentAt = CACurrentMediaTime()

        await send(.mouseScroll(dx: dx, dy: dy))
    }

    // MARK: - Immediate sends (clicks, shortcuts, etc.)

    func sendClick(_ button: MouseButton) async {
        await send(.mouseClick(button: button))
    }

    func sendDoubleClick(_ button: MouseButton) async {
        await send(.mouseDoubleClick(button: button))
    }

    func sendShortcut(_ keys: [String]) async {
        await send(.keyboardShortcut(keys: keys))
    }

    func sendMacro(_ id: String) async {
        await send(.macroButton(id: id))
    }

    func sendLaunchApp(_ bundleID: String) async {
        await send(.launchApp(bundleID: bundleID))
    }

    /// Activate `bundleID` on the Mac and inject `keys` once it's frontmost.
    /// Single message — the host coordinates the ordering so the shortcut
    /// doesn't leak into whatever window was previously focused.
    func sendAppShortcut(bundleID: String, keys: [String]) async {
        await send(.appShortcut(bundleID: bundleID, keys: keys))
    }

    /// Asks the Mac to walk `bundleID`'s menu bar via Accessibility and
    /// return every shortcut it advertises.
    func requestMenuShortcuts(bundleID: String) async {
        await send(.requestAppMenuShortcuts(bundleID: bundleID))
    }

    func sendMediaAction(_ action: String) async {
        await send(.mediaCommand(action: action))
    }

    /// Tells the Mac to press the dialog button identified by `id` from the
    /// latest `uiContextUpdate` snapshot. If the snapshot has since been
    /// superseded the Mac silently ignores it.
    func sendContextAction(id: String) async {
        await send(.triggerContextAction(id: id))
    }

    /// Issues a screenshot request tagged with `requestID` so the iPad can
    /// reject responses that belong to a previous, timed-out request.
    func requestScreenshot(requestID: String) async {
        await send(.requestScreenshot(requestID: requestID))
    }

    func requestAppList() async {
        await send(.requestAppList)
    }

    /// Maps 3-finger swipe directions to the same keyboard shortcuts
    /// that macOS uses for trackpad gestures.
    func sendThreeFingerSwipe(_ direction: TrackpadGestureKind.ThreeFingerDirection) async {
        switch direction {
        case .left:  await send(.keyboardShortcut(keys: ["ctrl", "left"]))
        case .right: await send(.keyboardShortcut(keys: ["ctrl", "right"]))
        // Mission Control & Exposé need dedicated handling on Mac
        case .up:    await send(.macroButton(id: "missioncontrol_trigger"))
        case .down:  await send(.macroButton(id: "expose_trigger"))
        }
    }

    // MARK: - Core send

    private func send(_ message: ControlMessage) async {
        try? await handle.send(message)
    }
}

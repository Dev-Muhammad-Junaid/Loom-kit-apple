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
    private let encoder = JSONEncoder()

    // ── Timing ──────────────────────────────────────────────────────
    // 120 Hz matches iPad Pro's ProMotion refresh rate so no touch
    // data is thrown away.  On non-ProMotion iPads (60 Hz) this just
    // means the cap is never hit.
    private let minimumInterval: Double = 1.0 / 120.0
    private var lastSentAt: Double = 0          // CACurrentMediaTime()

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
        let elapsed = now - lastSentAt

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
        lastSentAt = CACurrentMediaTime()

        await send(.mouseDelta(dx: dx, dy: dy))
    }

    // MARK: - Throttled scroll (120 Hz)

    func sendScroll(dx: Float, dy: Float) async {
        pendingScrollDX += dx
        pendingScrollDY += dy

        let now = CACurrentMediaTime()
        let elapsed = now - lastSentAt

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
        lastSentAt = CACurrentMediaTime()

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

    func sendMediaAction(_ action: String) async {
        await send(.mediaCommand(action: action))
    }

    func requestScreenshot() async {
        await send(.requestScreenshot)
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
        guard let data = try? encoder.encode(message) else { return }
        try? await handle.send(data)
    }
}

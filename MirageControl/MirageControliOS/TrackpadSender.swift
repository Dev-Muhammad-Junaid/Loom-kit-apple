//
//  TrackpadSender.swift
//  MirageControliOS
//

import Foundation
import LoomKit

/// Actor that owns the active connection handle and throttles outgoing control messages.
actor TrackpadSender {
    private let handle: LoomConnectionHandle
    private let encoder = JSONEncoder()
    private var lastSentAt: Date = .distantPast
    private let minimumInterval: TimeInterval = 1.0 / 60.0  // 60 Hz cap

    init(handle: LoomConnectionHandle) {
        self.handle = handle
    }

    private var pendingDeltaX: Float = 0
    private var pendingDeltaY: Float = 0
    private var isSendScheduled: Bool = false

    // MARK: - Throttled mouse delta

    func sendMouseDelta(dx: Float, dy: Float) async {
        pendingDeltaX += dx
        pendingDeltaY += dy
        
        let now = Date()
        let timeSinceLastSend = now.timeIntervalSince(lastSentAt)
        
        if timeSinceLastSend >= minimumInterval {
            await flushMouseDelta()
        } else if !isSendScheduled {
            isSendScheduled = true
            let delay = minimumInterval - timeSinceLastSend
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
        lastSentAt = Date()
        
        await send(.mouseDelta(dx: dx, dy: dy))
    }

    // MARK: - Immediate sends (clicks, shortcuts, etc.)

    func sendScroll(dx: Float, dy: Float) async {
        await send(.mouseScroll(dx: dx, dy: dy))
    }

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

    // MARK: - Core send

    private func send(_ message: ControlMessage) async {
        guard let data = try? encoder.encode(message) else { return }
        try? await handle.send(data)
    }
}

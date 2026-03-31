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

    // MARK: - Throttled mouse delta

    func sendMouseDelta(dx: Float, dy: Float) async {
        let now = Date()
        guard now.timeIntervalSince(lastSentAt) >= minimumInterval else { return }
        lastSentAt = now
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

    // MARK: - Core send

    private func send(_ message: ControlMessage) async {
        guard let data = try? encoder.encode(message) else { return }
        try? await handle.send(data)
    }
}

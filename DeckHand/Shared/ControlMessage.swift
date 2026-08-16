//
//  ControlMessage.swift
//  Deck Hand – Shared
//

import Foundation

// MARK: - Top-level message envelope

public enum ControlMessage: Codable, Sendable {
    case mouseDelta(dx: Float, dy: Float)
    /// Continuous scroll delta tagged with a `ScrollPhase` so the host can
    /// emit native trackpad-style scroll events (with rubber-banding +
    /// momentum) instead of unphased mouse-wheel ticks.
    case mouseScroll(dx: Float, dy: Float, phase: ScrollPhase)
    case mouseClick(button: MouseButton)
    case mouseDoubleClick(button: MouseButton)
    case keyboardShortcut(keys: [String])
    case launchApp(bundleID: String)
    case macroButton(id: String)
    case authorizationStatus(status: String)
    
    // Bidirectional/New Features
    /// iPad → Mac: request a fresh screen capture. `requestID` is echoed back
    /// in the response so a slow, late-arriving capture from a previous tap
    /// can't hijack the UI of the next request. `mode` lets the iPad pick
    /// between full-screen, a normalized region, or a single window.
    case requestScreenshot(requestID: String, mode: CaptureMode, quality: CaptureQuality = .standard)
    case mediaCommand(action: String)
    case screenshotData(requestID: String, data: Data)
    case screenshotError(requestID: String, message: String)
    case activeAppUpdate(name: String, bundleID: String?)

    /// iPad → Mac: enumerate currently visible user-facing windows so the
    /// iPad can populate its window picker. Reply: `windowListResponse`.
    case requestWindowList(requestID: String)
    /// Mac → iPad: snapshot of visible windows at request time.
    case windowListResponse(requestID: String, windows: [WindowInfo])

    // App Launcher
    case requestAppList
    case appListResponse(apps: [InstalledAppInfo])

    /// Activate `bundleID` on the Mac, wait for it to become frontmost, and
    /// inject `keys`. Kept separate from `keyboardShortcut` so shortcut
    /// triggers always land in the intended app, even when the user taps
    /// quickly after launching something else.
    case appShortcut(bundleID: String, keys: [String])

    /// iPad asks the Mac to enumerate every shortcut in `bundleID`'s menu
    /// bar via Accessibility, and reply with `appMenuShortcutsResponse`.
    case requestAppMenuShortcuts(bundleID: String)
    /// Host's reply to `requestAppMenuShortcuts`. Empty array means the app
    /// wasn't running or had no menu shortcuts we could read.
    case appMenuShortcutsResponse(bundleID: String, shortcuts: [AppShortcutBinding])

    /// Mac → iPad: all currently running user-facing apps, ordered by most-
    /// recent activation (Cmd+Tab order). Sent unsolicited on connection and
    /// on every launch / terminate / activate. iPad maps bundle IDs to icons
    /// from its existing `installedApps` cache — no icon payload needed.
    case runningAppsUpdate(bundleIDs: [String])

    /// Mac → iPad: what's currently interactable on the frontmost app, as
    /// seen through Accessibility. Phase 1 carries dialog/sheet button
    /// snapshots so the iPad can surface "Cancel / Don't Save / Save"
    /// chips in the Quick Actions bar. `.none` means fall back to regular
    /// per-app shortcut chips.
    case uiContextUpdate(snapshot: UIContextSnapshot)

    /// iPad → Mac: the user tapped a dialog button. `id` is an opaque
    /// handle from the most recent `uiContextUpdate` snapshot; the Mac
    /// looks up its stored AX element reference and performs `kAXPressAction`.
    /// Stale IDs (after the snapshot has been superseded) are ignored.
    case triggerContextAction(id: String)

    // ── Live mini mirror (WID-403) ───────────────────────────────────
    /// iPad → Mac: start streaming low-res screen frames. `fps` caps the
    /// capture rate (the Mac may deliver fewer under load); `maxWidth`
    /// bounds the longest frame edge in pixels so the host downsamples
    /// on the GPU before encoding.
    case startMirror(fps: Int, maxWidth: Int)
    /// iPad → Mac: stop the mirror stream. Also implied by disconnect.
    case stopMirror
    /// Mac → iPad: one JPEG frame. `seq` increases monotonically within a
    /// stream so the iPad can drop out-of-order/stale frames; frames are
    /// independent (no inter-frame state) so any frame may be dropped.
    case mirrorFrame(seq: UInt64, data: Data)

    /// iPad → Mac: "what's my authorization state?" Self-healing resync for
    /// the approval handshake. Status pushes ride best-effort sends — if the
    /// host's `granted` ever fails to transmit, the iPad would otherwise
    /// wait on the approval overlay forever while the host believes the
    /// session is live. The iPad polls this while it hasn't heard a status;
    /// the host replies with `authorizationStatus`. While the request is
    /// still pending the host intentionally doesn't consume messages, so
    /// queries buffer in the handle and are answered the moment the
    /// connection is approved — exactly the resync we want.
    case requestAuthorizationStatus

    // ── Application-level liveness ───────────────────────────────────
    /// iPad → Mac, every ~2 s while a session is active. The transport's
    /// own state can lag reality badly after abrupt kills (buffered
    /// streams, half-open TCP), so liveness is proven at the protocol
    /// level: each side trusts only recent ping/pong traffic.
    case ping(seq: UInt64)
    /// Mac → iPad: echo of `ping`. Missing pongs ⇒ host is gone — the
    /// iPad returns to the picker instead of showing a zombie session.
    /// Missing pings ⇒ iPad is gone — the host drops the connection and
    /// stops consuming its buffered commands.
    case pong(seq: UInt64)

    /// Mac → iPad: what the host can actually DO right now. Sent when a
    /// session starts and re-checked periodically, so the remote can show
    /// "the Mac is missing Accessibility permission" instead of letting
    /// taps fail silently. `accessibility` gates input injection +
    /// dialog/menu features; `screenRecording` gates screenshots + mirror.
    case hostCapabilities(accessibility: Bool, screenRecording: Bool)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, dx, dy, button, keys, bundleID, bundleIDs, id, status, action, data, name, message, apps, shortcuts, snapshot, requestID, mode, quality, windows, phase, fps, maxWidth, seq, accessibility, screenRecording
    }

    private enum MessageType: String, Codable {
        case mouseDelta, mouseScroll, mouseClick, mouseDoubleClick
        case keyboardShortcut, launchApp, macroButton, authorizationStatus
        case requestScreenshot, mediaCommand, screenshotData, screenshotError, activeAppUpdate
        case requestWindowList, windowListResponse
        case requestAppList, appListResponse
        case appShortcut
        case requestAppMenuShortcuts, appMenuShortcutsResponse
        case runningAppsUpdate
        case uiContextUpdate, triggerContextAction
        case startMirror, stopMirror, mirrorFrame
        case requestAuthorizationStatus
        case ping, pong
        case hostCapabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(MessageType.self, forKey: .type)
        switch type {
        case .mouseDelta:
            self = .mouseDelta(dx: try c.decode(Float.self, forKey: .dx),
                               dy: try c.decode(Float.self, forKey: .dy))
        case .mouseScroll:
            // `phase` defaults to `.changed` for back-compat with builds
            // that haven't been bumped to send phased scroll yet.
            let phase = try c.decodeIfPresent(ScrollPhase.self, forKey: .phase) ?? .changed
            self = .mouseScroll(
                dx: try c.decode(Float.self, forKey: .dx),
                dy: try c.decode(Float.self, forKey: .dy),
                phase: phase
            )
        case .mouseClick:
            self = .mouseClick(button: try c.decode(MouseButton.self, forKey: .button))
        case .mouseDoubleClick:
            self = .mouseDoubleClick(button: try c.decode(MouseButton.self, forKey: .button))
        case .keyboardShortcut:
            self = .keyboardShortcut(keys: try c.decode([String].self, forKey: .keys))
        case .launchApp:
            self = .launchApp(bundleID: try c.decode(String.self, forKey: .bundleID))
        case .macroButton:
            self = .macroButton(id: try c.decode(String.self, forKey: .id))
        case .authorizationStatus:
            self = .authorizationStatus(status: try c.decode(String.self, forKey: .status))
        case .requestScreenshot:
            // `mode` and `quality` are optional for back-compat; missing
            // implies a standard-quality full-screen capture.
            let mode = try c.decodeIfPresent(CaptureMode.self, forKey: .mode) ?? .fullScreen
            let quality = try c.decodeIfPresent(CaptureQuality.self, forKey: .quality) ?? .standard
            self = .requestScreenshot(
                requestID: try c.decode(String.self, forKey: .requestID),
                mode: mode,
                quality: quality
            )
        case .requestWindowList:
            self = .requestWindowList(
                requestID: try c.decode(String.self, forKey: .requestID)
            )
        case .windowListResponse:
            self = .windowListResponse(
                requestID: try c.decode(String.self, forKey: .requestID),
                windows: try c.decode([WindowInfo].self, forKey: .windows)
            )
        case .mediaCommand:
            self = .mediaCommand(action: try c.decode(String.self, forKey: .action))
        case .screenshotData:
            self = .screenshotData(
                requestID: try c.decode(String.self, forKey: .requestID),
                data: try c.decode(Data.self, forKey: .data)
            )
        case .screenshotError:
            self = .screenshotError(
                requestID: try c.decode(String.self, forKey: .requestID),
                message: try c.decode(String.self, forKey: .message)
            )
        case .activeAppUpdate:
            self = .activeAppUpdate(name: try c.decode(String.self, forKey: .name),
                                    bundleID: try c.decodeIfPresent(String.self, forKey: .bundleID))
        case .requestAppList:
            self = .requestAppList
        case .appListResponse:
            self = .appListResponse(apps: try c.decode([InstalledAppInfo].self, forKey: .apps))
        case .appShortcut:
            self = .appShortcut(
                bundleID: try c.decode(String.self, forKey: .bundleID),
                keys: try c.decode([String].self, forKey: .keys)
            )
        case .requestAppMenuShortcuts:
            self = .requestAppMenuShortcuts(
                bundleID: try c.decode(String.self, forKey: .bundleID)
            )
        case .appMenuShortcutsResponse:
            self = .appMenuShortcutsResponse(
                bundleID: try c.decode(String.self, forKey: .bundleID),
                shortcuts: try c.decode([AppShortcutBinding].self, forKey: .shortcuts)
            )
        case .runningAppsUpdate:
            self = .runningAppsUpdate(
                bundleIDs: try c.decode([String].self, forKey: .bundleIDs)
            )
        case .uiContextUpdate:
            self = .uiContextUpdate(
                snapshot: try c.decode(UIContextSnapshot.self, forKey: .snapshot)
            )
        case .triggerContextAction:
            self = .triggerContextAction(id: try c.decode(String.self, forKey: .id))
        case .startMirror:
            self = .startMirror(
                fps: try c.decode(Int.self, forKey: .fps),
                maxWidth: try c.decode(Int.self, forKey: .maxWidth)
            )
        case .stopMirror:
            self = .stopMirror
        case .mirrorFrame:
            self = .mirrorFrame(
                seq: try c.decode(UInt64.self, forKey: .seq),
                data: try c.decode(Data.self, forKey: .data)
            )
        case .requestAuthorizationStatus:
            self = .requestAuthorizationStatus
        case .ping:
            self = .ping(seq: try c.decode(UInt64.self, forKey: .seq))
        case .pong:
            self = .pong(seq: try c.decode(UInt64.self, forKey: .seq))
        case .hostCapabilities:
            self = .hostCapabilities(
                accessibility: try c.decode(Bool.self, forKey: .accessibility),
                screenRecording: try c.decode(Bool.self, forKey: .screenRecording)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .mouseDelta(dx, dy):
            try c.encode(MessageType.mouseDelta, forKey: .type)
            try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case let .mouseScroll(dx, dy, phase):
            try c.encode(MessageType.mouseScroll, forKey: .type)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
            try c.encode(phase, forKey: .phase)
        case let .mouseClick(button):
            try c.encode(MessageType.mouseClick, forKey: .type)
            try c.encode(button, forKey: .button)
        case let .mouseDoubleClick(button):
            try c.encode(MessageType.mouseDoubleClick, forKey: .type)
            try c.encode(button, forKey: .button)
        case let .keyboardShortcut(keys):
            try c.encode(MessageType.keyboardShortcut, forKey: .type)
            try c.encode(keys, forKey: .keys)
        case let .launchApp(bundleID):
            try c.encode(MessageType.launchApp, forKey: .type)
            try c.encode(bundleID, forKey: .bundleID)
        case let .macroButton(id):
            try c.encode(MessageType.macroButton, forKey: .type)
            try c.encode(id, forKey: .id)
        case let .authorizationStatus(status):
            try c.encode(MessageType.authorizationStatus, forKey: .type)
            try c.encode(status, forKey: .status)
        case let .requestScreenshot(requestID, mode, quality):
            try c.encode(MessageType.requestScreenshot, forKey: .type)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(mode, forKey: .mode)
            try c.encode(quality, forKey: .quality)
        case let .requestWindowList(requestID):
            try c.encode(MessageType.requestWindowList, forKey: .type)
            try c.encode(requestID, forKey: .requestID)
        case let .windowListResponse(requestID, windows):
            try c.encode(MessageType.windowListResponse, forKey: .type)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(windows, forKey: .windows)
        case let .mediaCommand(action):
            try c.encode(MessageType.mediaCommand, forKey: .type)
            try c.encode(action, forKey: .action)
        case let .screenshotData(requestID, data):
            try c.encode(MessageType.screenshotData, forKey: .type)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(data, forKey: .data)
        case let .screenshotError(requestID, message):
            try c.encode(MessageType.screenshotError, forKey: .type)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(message, forKey: .message)
        case let .activeAppUpdate(name, bundleID):
            try c.encode(MessageType.activeAppUpdate, forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(bundleID, forKey: .bundleID)
        case .requestAppList:
            try c.encode(MessageType.requestAppList, forKey: .type)
        case let .appListResponse(apps):
            try c.encode(MessageType.appListResponse, forKey: .type)
            try c.encode(apps, forKey: .apps)
        case let .appShortcut(bundleID, keys):
            try c.encode(MessageType.appShortcut, forKey: .type)
            try c.encode(bundleID, forKey: .bundleID)
            try c.encode(keys, forKey: .keys)
        case let .requestAppMenuShortcuts(bundleID):
            try c.encode(MessageType.requestAppMenuShortcuts, forKey: .type)
            try c.encode(bundleID, forKey: .bundleID)
        case let .appMenuShortcutsResponse(bundleID, shortcuts):
            try c.encode(MessageType.appMenuShortcutsResponse, forKey: .type)
            try c.encode(bundleID, forKey: .bundleID)
            try c.encode(shortcuts, forKey: .shortcuts)
        case let .runningAppsUpdate(bundleIDs):
            try c.encode(MessageType.runningAppsUpdate, forKey: .type)
            try c.encode(bundleIDs, forKey: .bundleIDs)
        case let .uiContextUpdate(snapshot):
            try c.encode(MessageType.uiContextUpdate, forKey: .type)
            try c.encode(snapshot, forKey: .snapshot)
        case let .triggerContextAction(id):
            try c.encode(MessageType.triggerContextAction, forKey: .type)
            try c.encode(id, forKey: .id)
        case let .startMirror(fps, maxWidth):
            try c.encode(MessageType.startMirror, forKey: .type)
            try c.encode(fps, forKey: .fps)
            try c.encode(maxWidth, forKey: .maxWidth)
        case .stopMirror:
            try c.encode(MessageType.stopMirror, forKey: .type)
        case let .mirrorFrame(seq, data):
            try c.encode(MessageType.mirrorFrame, forKey: .type)
            try c.encode(seq, forKey: .seq)
            try c.encode(data, forKey: .data)
        case .requestAuthorizationStatus:
            try c.encode(MessageType.requestAuthorizationStatus, forKey: .type)
        case let .ping(seq):
            try c.encode(MessageType.ping, forKey: .type)
            try c.encode(seq, forKey: .seq)
        case let .pong(seq):
            try c.encode(MessageType.pong, forKey: .type)
            try c.encode(seq, forKey: .seq)
        case let .hostCapabilities(accessibility, screenRecording):
            try c.encode(MessageType.hostCapabilities, forKey: .type)
            try c.encode(accessibility, forKey: .accessibility)
            try c.encode(screenRecording, forKey: .screenRecording)
        }
    }
}

// MARK: - Supporting types

public enum MouseButton: String, Codable, Sendable {
    case left, right, middle
}

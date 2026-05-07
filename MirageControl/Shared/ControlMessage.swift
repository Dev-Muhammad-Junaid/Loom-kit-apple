//
//  ControlMessage.swift
//  MirageControl – Shared
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
    case requestScreenshot(requestID: String, mode: CaptureMode)
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

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, dx, dy, button, keys, bundleID, bundleIDs, id, status, action, data, name, message, apps, shortcuts, snapshot, requestID, mode, windows, phase
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
            // `mode` is optional for back-compat; missing implies full-screen.
            let mode = try c.decodeIfPresent(CaptureMode.self, forKey: .mode) ?? .fullScreen
            self = .requestScreenshot(
                requestID: try c.decode(String.self, forKey: .requestID),
                mode: mode
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
        case let .requestScreenshot(requestID, mode):
            try c.encode(MessageType.requestScreenshot, forKey: .type)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(mode, forKey: .mode)
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
        }
    }
}

// MARK: - Supporting types

public enum MouseButton: String, Codable, Sendable {
    case left, right, middle
}

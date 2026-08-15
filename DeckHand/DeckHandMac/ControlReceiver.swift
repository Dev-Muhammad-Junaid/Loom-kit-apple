//
//  ControlReceiver.swift
//  DeckHandMac
//

import AppKit
import Foundation
import LoomKit

/// Receives incoming Loom connections and routes decoded ControlMessages
/// to InputInjector and AppLauncher.
@MainActor
final class ControlReceiver {
    private let injector = InputInjector.shared
    private let launcher = AppLauncher.shared
    /// Consume tasks keyed by `handle.id` so authorization revocation and
    /// liveness timeouts can cancel consumption *immediately* — buffered
    /// commands from a dead/revoked iPad are dropped, never replayed.
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var connectionHandles: [UUID: LoomConnectionHandle] = [:]
    /// Last time any message arrived per connection, and whether the peer
    /// has ever pinged (heartbeat-capable builds only get the timeout).
    private var lastActivityAt: [UUID: Date] = [:]
    private var hasPinged: Set<UUID> = []
    private var livenessSweepTask: Task<Void, Never>?
    /// Sampled counter for high-rate input logging (see consumeMessages).
    private var inputMessageCount = 0

    /// Connections silent for longer than this (after having pinged at
    /// least once — i.e. provably heartbeat-capable) are declared dead.
    /// The iPad pings every 2 s, so 8 s = four missed beats.
    private static let livenessTimeout: TimeInterval = 8

    /// Called from MacMenuBarView for each newly established incoming connection.
    func observeConnection(_ connectionHandle: LoomConnectionHandle) {
        let key = connectionHandle.id
        connectionHandles[key] = connectionHandle
        lastActivityAt[key] = Date()
        startLivenessSweepIfNeeded()
        connectionTasks[key] = Task { [weak self] in
            ActiveAppMonitor.shared.addConnection(connectionHandle, id: key)
            RunningAppMonitor.shared.addConnection(connectionHandle, id: key)
            ContextObserver.shared.addConnection(connectionHandle, id: key)
            // Tell the remote up front what this host can actually do, so
            // it can explain missing permissions instead of failing silently.
            await self?.sendCapabilities(to: connectionHandle)
            await self?.consumeMessages(from: connectionHandle)
            // The message loop has ended (stream finished, task cancelled
            // by revocation, or liveness timeout). Stop any mirror stream
            // so capture doesn't burn CPU/GPU against a dead handle.
            await MirrorStreamService.shared.stop(subscriberID: key)
            _ = await MainActor.run { [weak self] in
                self?.cleanupConnection(key)
            }
        }
    }

    /// Immediately stops consuming a connection's messages. Called on
    /// authorization revocation and liveness timeout: any commands the
    /// iPad queued before dying are discarded instead of executed.
    func cancelConsumption(connectionID: UUID) {
        guard let task = connectionTasks[connectionID] else { return }
        #if DEBUG
        print("Deck Hand: 🛑 cancelling consumption for \(connectionID) (revoked or liveness timeout)")
        #endif
        task.cancel()
    }

    private func cleanupConnection(_ key: UUID) {
        connectionTasks.removeValue(forKey: key)
        connectionHandles.removeValue(forKey: key)
        lastActivityAt.removeValue(forKey: key)
        hasPinged.remove(key)
        ActiveAppMonitor.shared.removeConnection(id: key)
        RunningAppMonitor.shared.removeConnection(id: key)
        ContextObserver.shared.removeConnection(id: key)
    }

    /// Periodic check: any heartbeat-capable connection that has gone
    /// silent past the timeout is dead — cancel its consumption and
    /// disconnect the handle so the menu bar stops showing a zombie row.
    private func startLivenessSweepIfNeeded() {
        guard livenessSweepTask == nil else { return }
        livenessSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await self?.sweepDeadConnections()
            }
        }
    }

    private func sweepDeadConnections() async {
        let now = Date()
        for (key, lastSeen) in lastActivityAt
        where hasPinged.contains(key) && now.timeIntervalSince(lastSeen) > Self.livenessTimeout {
            DeckHandLog.connection.info("Liveness timeout for connection \(key, privacy: .public) — dropping")
            cancelConsumption(connectionID: key)
            if let handle = connectionHandles[key] {
                Task { await handle.disconnect() }
            }
            cleanupConnection(key)
        }
    }

    private func consumeMessages(from connectionHandle: LoomConnectionHandle) async {
        for await data in connectionHandle.messages {
            // Honors cancelConsumption: stop dispatching the moment the
            // connection is revoked or timed out, even with a backlog.
            if Task.isCancelled { return }
            lastActivityAt[connectionHandle.id] = Date()
            let message: ControlMessage
            do {
                message = try ControlMessageCoding.decoder.decode(ControlMessage.self, from: data)
            } catch {
                #if DEBUG
                print("Deck Hand: ⚠️ Failed to decode ControlMessage (\(data.count)B): \(error)")
                #endif
                continue
            }
            // Arrival visibility: when the iPad "does nothing", the first
            // question is whether its messages reach this loop at all. Logged
            // through DeckHandLog (always-on) so this is visible in Console.app
            // for release/TestFlight builds, not just Xcode-attached DEBUG.
            // High-rate input is sampled so the stream stays readable.
            switch message {
            case .mouseDelta, .mouseScroll:
                inputMessageCount += 1
                if inputMessageCount % 120 == 1 {
                    DeckHandLog.input.info("📥 input stream alive (\(self.inputMessageCount) input messages received)")
                }
            default:
                DeckHandLog.connection.debug("📥 dispatching \(String(describing: message), privacy: .public)")
            }
            await dispatch(message, handle: connectionHandle)
        }
        DeckHandLog.connection.info("📪 message loop ended for \(connectionHandle.id, privacy: .public) (peer disconnected, revoked, or session replaced)")
    }

    private func dispatch(_ message: ControlMessage, handle: LoomConnectionHandle) async {
        switch message {
        case let .mouseDelta(dx, dy):
            injector.moveCursor(dx: dx, dy: dy)

        case let .mouseScroll(dx, dy, phase):
            injector.scroll(dx: dx, dy: dy, phase: Self.injectorPhase(for: phase))

        case let .mouseClick(button):
            injector.click(button: button)

        case let .mouseDoubleClick(button):
            injector.click(button: button, double: true)

        case let .keyboardShortcut(keys):
            injector.sendShortcut(keys: keys)

        // ── Slow / potentially-blocking operations ───────────────────
        // CRITICAL: these run in their OWN tasks. The message loop awaits
        // dispatch serially, and several of these can stall for seconds —
        // ScreenCaptureKit calls are documented to hang outright when the
        // TCC grant is wedged. One hung handler used to freeze the entire
        // loop: input went dead, pongs stopped (so liveness killed the
        // connection), and the queued backlog of commands fired all at
        // once when the connection finally tore down.

        case let .launchApp(bundleID):
            Task { await self.launcher.launch(bundleID: bundleID) }

        case let .appShortcut(bundleID, keys):
            // Activate the target app, wait for it to become frontmost
            // (≤600 ms), then inject — self-contained ordering inside its
            // own task.
            Task {
                await self.launcher.activateAndWait(bundleID: bundleID)
                self.injector.sendShortcut(keys: keys)
            }

        case let .macroButton(id):
            Task { await self.dispatchMacro(id: id) }

        case let .mediaCommand(action):
            switch action {
            case "playpause": injector.sendMediaKey(NX_KEYTYPE_PLAY)
            case "next":      injector.sendMediaKey(NX_KEYTYPE_NEXT)
            case "prev":      injector.sendMediaKey(NX_KEYTYPE_PREVIOUS)
            default: break
            }
            
        case let .requestScreenshot(requestID, mode):
            Task { await self.handleScreenshotRequest(requestID: requestID, mode: mode, handle: handle) }

        case let .requestWindowList(requestID):
            Task { await self.handleWindowListRequest(requestID: requestID, handle: handle) }

        case .requestAppList:
            Task { await self.handleAppListRequest(handle: handle) }

        case let .requestAppMenuShortcuts(bundleID):
            Task { await self.handleMenuShortcutsRequest(bundleID: bundleID, handle: handle) }

        case let .triggerContextAction(id):
            // AXUIElementPerformAction can block up to the AX messaging
            // timeout (~6 s) on an unresponsive app — own task.
            Task { ContextObserver.shared.performAction(id: id) }

        case let .startMirror(fps, maxWidth):
            // SCShareableContent inside — the #1 hang candidate. Own task.
            let subscriberID = handle.id
            Task {
                await MirrorStreamService.shared.start(
                    subscriberID: subscriberID,
                    handle: handle,
                    fps: fps,
                    maxWidth: maxWidth
                )
            }

        case .stopMirror:
            let subscriberID = handle.id
            Task { await MirrorStreamService.shared.stop(subscriberID: subscriberID) }

        case let .ping(seq):
            hasPinged.insert(handle.id)
            try? await handle.send(.pong(seq: seq))
            // Re-report capabilities every 5th ping (~10 s): if the user
            // grants/revokes a TCC permission mid-session the remote's
            // warning banner updates without reconnecting.
            if seq % 5 == 0 {
                await sendCapabilities(to: handle)
            }

        case .pong:
            break // host never receives pongs

        case .requestAuthorizationStatus:
            // Resync path: messages are only consumed for *authorized*
            // connections (DeviceAuthorizationManager gates the handoff),
            // so reaching this dispatch means the answer is "granted".
            // Queries sent while the request was pending sit buffered in
            // the handle and get answered here right after approval —
            // healing any lost/failed `granted` push.
            do {
                try await handle.send(.authorizationStatus(status: "granted"))
            } catch {
                DeckHandLog.connection.error("Failed to answer auth-status query: \(error.localizedDescription, privacy: .public)")
            }

        case .authorizationStatus:
            break
        case .screenshotData, .screenshotError, .activeAppUpdate, .appListResponse, .appMenuShortcutsResponse, .runningAppsUpdate, .uiContextUpdate, .windowListResponse, .mirrorFrame, .hostCapabilities:
            // Client-bound messages; host doesn't process them locally
            break
        }
    }

    // MARK: - Screenshot Permission

    /// Call once at startup so macOS has already shown the prompt before the user
    /// taps the screenshot button on their iPad. Touches `SCShareableContent` to
    /// surface the TCC dialog on first launch.
    func requestScreenCaptureIfNeeded() {
        Task { await ScreenCaptureService.shared.primePermission() }
    }

    // MARK: - Screenshot Capture

    /// Captures the requested slice of the screen and sends it back as JPEG,
    /// or sends a descriptive `screenshotError` so the iPad can dismiss its
    /// spinner and show a useful message. `requestID` is echoed verbatim so
    /// the iPad can drop responses belonging to a timed-out earlier tap.
    private func handleScreenshotRequest(
        requestID: String,
        mode: CaptureMode,
        handle: LoomConnectionHandle
    ) async {
        do {
            // Format is per-mode now: full-screen is JPEG (small payloads
            // for the common case), region and window are PNG (lossless,
            // alpha-preserving). Callers on the iPad just decode via
            // UIImage(data:) so they don't care which.
            let payload: Data
            switch mode {
            case .fullScreen:
                payload = try await ScreenCaptureService.shared.captureMainDisplayJPEG()
            case let .region(x, y, width, height):
                let rect = CGRect(
                    x: CGFloat(x),
                    y: CGFloat(y),
                    width: CGFloat(width),
                    height: CGFloat(height)
                )
                payload = try await ScreenCaptureService.shared.captureRegion(normalizedRect: rect)
            case let .window(windowID):
                payload = try await ScreenCaptureService.shared.captureWindowJPEG(windowID: windowID)
            }
            try await handle.send(.screenshotData(requestID: requestID, data: payload))
        } catch ScreenCaptureService.CaptureError.permissionDenied {
            await sendError(requestID: requestID, to: handle,
                            message: "Screen Recording permission required. Please allow Deck Hand in System Settings > Privacy & Security > Screen Recording, then try again.")
        } catch ScreenCaptureService.CaptureError.noDisplay {
            await sendError(requestID: requestID, to: handle, message: "Display capture failed. No displays found.")
        } catch ScreenCaptureService.CaptureError.windowNotFound {
            await sendError(requestID: requestID, to: handle,
                            message: "That window has closed. Refresh the window list and try again.")
        } catch ScreenCaptureService.CaptureError.captureFailed(let detail) {
            await sendError(requestID: requestID, to: handle, message: "Capture failed: \(detail)")
        } catch ScreenCaptureService.CaptureError.encodeFailed {
            await sendError(requestID: requestID, to: handle, message: "Image compression failed.")
        } catch {
            await sendError(requestID: requestID, to: handle,
                            message: "Unexpected capture error: \(error.localizedDescription)")
        }
    }

    private func handleWindowListRequest(requestID: String, handle: LoomConnectionHandle) async {
        do {
            let windows = try await ScreenCaptureService.shared.enumerateWindows()
            try await handle.send(.windowListResponse(requestID: requestID, windows: windows))
        } catch {
            // Window enumeration failures share the same TCC requirement as
            // capture, so route them through the same error channel — the
            // iPad already knows how to surface this copy.
            await sendError(
                requestID: requestID,
                to: handle,
                message: "Couldn't read window list: \(error.localizedDescription)"
            )
        }
    }

    /// Reports what this host can actually execute. Accessibility is read
    /// live (cheap); screen recording uses the preflight toggle — the
    /// PermissionsMonitor probe is authoritative for local UI, but for the
    /// remote's banner the toggle is a good-enough, allocation-free check.
    private func sendCapabilities(to handle: LoomConnectionHandle) async {
        try? await handle.send(.hostCapabilities(
            accessibility: injector.isAccessibilityGranted,
            screenRecording: CGPreflightScreenCaptureAccess()
        ))
    }

    private func sendError(requestID: String, to handle: LoomConnectionHandle, message: String) async {
        try? await handle.send(.screenshotError(requestID: requestID, message: message))
    }

    private func dispatchMacro(id: String) async {
        // System-level triggers that can't be done via CGEvent keyboard shortcuts
        switch id {
        case "locate_cursor":
            CursorLocator.shared.ping()
            return
        case "missioncontrol_trigger":
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", "Mission Control"]
            try? proc.run()
            return
        case "expose_trigger":
            // App Exposé isn't a standalone app — trigger via AppleScript
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "tell application \"System Events\" to key code 125 using control down"]
            try? proc.run()
            return
        case "launchpad_trigger":
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", "Launchpad"]
            try? proc.run()
            return
        default:
            break
        }

        // Standard MacroItem lookup
        if let item = MacroItem.defaultDeck.first(where: { $0.id == id }) {
            switch item {
            case .app(let app):
                await launcher.launch(bundleID: app.bundleID)
            case .shortcut(let s):
                injector.sendShortcut(keys: s.keys)
            case .media(let m):
                switch m.action {
                case "playpause": injector.sendMediaKey(NX_KEYTYPE_PLAY)
                case "next":      injector.sendMediaKey(NX_KEYTYPE_NEXT)
                case "prev":      injector.sendMediaKey(NX_KEYTYPE_PREVIOUS)
                default: break
                }
            }
        }
    }

    // MARK: - App List

    private func handleAppListRequest(handle: LoomConnectionHandle) async {
        let apps = InstalledAppScanner.shared.installedApps()
        try? await handle.send(.appListResponse(apps: apps))
    }

    private func handleMenuShortcutsRequest(bundleID: String, handle: LoomConnectionHandle) async {
        let shortcuts = await MenuShortcutDiscovery.discover(bundleID: bundleID, launcher: launcher)
        try? await handle.send(.appMenuShortcutsResponse(bundleID: bundleID, shortcuts: shortcuts))
    }

    func removeConnection(id: UUID) {
        connectionTasks[id]?.cancel()
        connectionTasks.removeValue(forKey: id)
        ActiveAppMonitor.shared.removeConnection(id: id)
        RunningAppMonitor.shared.removeConnection(id: id)
        ContextObserver.shared.removeConnection(id: id)
    }

    /// Bridge from the Shared wire enum to the Mac-internal `InputInjector`
    /// phase. We keep them as separate types so the iOS target doesn't
    /// pull in `InputInjector` and the Mac internals stay free to evolve.
    private static func injectorPhase(for phase: ScrollPhase) -> InputInjector.ScrollPhase {
        switch phase {
        case .begin:           return .begin
        case .changed:         return .changed
        case .end:             return .end
        case .momentumBegin:   return .momentumBegin
        case .momentumChanged: return .momentumChanged
        case .momentumEnd:     return .momentumEnd
        }
    }
}

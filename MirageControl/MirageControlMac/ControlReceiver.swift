//
//  ControlReceiver.swift
//  MirageControlMac
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
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    /// Called from MacMenuBarView for each newly established incoming connection.
    func observeConnection(_ connectionHandle: LoomConnectionHandle) {
        // Use a locally generated key — we can't synchronously read actor-isolated .id
        let taskKey = UUID()
        connectionTasks[taskKey] = Task { [weak self] in
            await ActiveAppMonitor.shared.addConnection(connectionHandle, id: taskKey)
            await RunningAppMonitor.shared.addConnection(connectionHandle, id: taskKey)
            await self?.consumeMessages(from: connectionHandle)
            _ = await MainActor.run { [weak self] in
                self?.connectionTasks.removeValue(forKey: taskKey)
                ActiveAppMonitor.shared.removeConnection(id: taskKey)
                RunningAppMonitor.shared.removeConnection(id: taskKey)
            }
        }
    }

    private func consumeMessages(from connectionHandle: LoomConnectionHandle) async {
        for await data in connectionHandle.messages {
            let message: ControlMessage
            do {
                message = try JSONDecoder().decode(ControlMessage.self, from: data)
            } catch {
                #if DEBUG
                print("MirageControl: ⚠️ Failed to decode ControlMessage (\(data.count)B): \(error)")
                #endif
                continue
            }
            await dispatch(message, handle: connectionHandle)
        }
    }

    private func dispatch(_ message: ControlMessage, handle: LoomConnectionHandle) async {
        switch message {
        case let .mouseDelta(dx, dy):
            injector.moveCursor(dx: dx, dy: dy)

        case let .mouseScroll(dx, dy):
            injector.scroll(dx: dx, dy: dy)

        case let .mouseClick(button):
            injector.click(button: button)

        case let .mouseDoubleClick(button):
            injector.click(button: button, double: true)

        case let .keyboardShortcut(keys):
            injector.sendShortcut(keys: keys)

        case let .launchApp(bundleID):
            await launcher.launch(bundleID: bundleID)

        case let .appShortcut(bundleID, keys):
            // Activate the target app, wait for it to become frontmost, then
            // inject. The wait is short (≤600 ms) but prevents the shortcut
            // from landing in whichever app happened to be focused when the
            // user tapped.
            await launcher.activateAndWait(bundleID: bundleID)
            injector.sendShortcut(keys: keys)

        case let .macroButton(id):
            await dispatchMacro(id: id)
            
        case let .mediaCommand(action):
            switch action {
            case "playpause": injector.sendMediaKey(NX_KEYTYPE_PLAY)
            case "next":      injector.sendMediaKey(NX_KEYTYPE_NEXT)
            case "prev":      injector.sendMediaKey(NX_KEYTYPE_PREVIOUS)
            default: break
            }
            
        case .requestScreenshot:
            await handleScreenshotRequest(handle: handle)

        case .requestAppList:
            await handleAppListRequest(handle: handle)

        case let .requestAppMenuShortcuts(bundleID):
            await handleMenuShortcutsRequest(bundleID: bundleID, handle: handle)

        case .authorizationStatus:
            break
        case .screenshotData, .screenshotError, .activeAppUpdate, .appListResponse, .appMenuShortcutsResponse, .runningAppsUpdate:
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

    /// Captures the main display via ScreenCaptureKit and sends the JPEG back,
    /// or sends a descriptive `screenshotError` so the iPad can dismiss its
    /// spinner and show a useful message.
    private func handleScreenshotRequest(handle: LoomConnectionHandle) async {
        do {
            let jpeg = try await ScreenCaptureService.shared.captureMainDisplayJPEG()
            try await handle.send(JSONEncoder().encode(ControlMessage.screenshotData(data: jpeg)))
        } catch ScreenCaptureService.CaptureError.permissionDenied {
            await sendError(to: handle,
                            message: "Screen Recording permission required. Please allow MirageControl in System Settings > Privacy & Security > Screen Recording, then try again.")
        } catch ScreenCaptureService.CaptureError.noDisplay {
            await sendError(to: handle, message: "Display capture failed. No displays found.")
        } catch ScreenCaptureService.CaptureError.captureFailed(let detail) {
            await sendError(to: handle, message: "Capture failed: \(detail)")
        } catch ScreenCaptureService.CaptureError.encodeFailed {
            await sendError(to: handle, message: "Image compression failed.")
        } catch {
            await sendError(to: handle, message: "Unexpected capture error: \(error.localizedDescription)")
        }
    }

    private func sendError(to handle: LoomConnectionHandle, message: String) async {
        try? await handle.send(try JSONEncoder().encode(ControlMessage.screenshotError(message: message)))
    }

    private func dispatchMacro(id: String) async {
        // System-level triggers that can't be done via CGEvent keyboard shortcuts
        switch id {
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
        let message = ControlMessage.appListResponse(apps: apps)
        try? await handle.send(try JSONEncoder().encode(message))
    }

    private func handleMenuShortcutsRequest(bundleID: String, handle: LoomConnectionHandle) async {
        let shortcuts = await MenuShortcutDiscovery.discover(bundleID: bundleID, launcher: launcher)
        let message = ControlMessage.appMenuShortcutsResponse(bundleID: bundleID, shortcuts: shortcuts)
        try? await handle.send(try JSONEncoder().encode(message))
    }

    func removeConnection(id: UUID) {
        connectionTasks[id]?.cancel()
        connectionTasks.removeValue(forKey: id)
        ActiveAppMonitor.shared.removeConnection(id: id)
        RunningAppMonitor.shared.removeConnection(id: id)
    }
}

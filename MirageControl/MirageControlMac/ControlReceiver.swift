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
            await self?.consumeMessages(from: connectionHandle)
            _ = await MainActor.run { [weak self] in
                self?.connectionTasks.removeValue(forKey: taskKey)
                ActiveAppMonitor.shared.removeConnection(id: taskKey)
            }
        }
    }

    private func consumeMessages(from connectionHandle: LoomConnectionHandle) async {
        for await data in connectionHandle.messages {
            guard let message = try? JSONDecoder().decode(ControlMessage.self, from: data) else {
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

        case .authorizationStatus, .screenshotData, .screenshotError, .activeAppUpdate, .appListResponse:
            // Client-bound messages; host doesn't process them locally
            break
        }
    }
    
    // MARK: - Screenshot Permission

    /// Call once at startup so macOS has already shown the prompt before the user
    /// taps the screenshot button on their iPad.
    func requestScreenCaptureIfNeeded() {
        if #available(macOS 11.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }
        }
    }

    // MARK: - Screenshot Capture

    /// Validates permission, captures the display on a background thread, compresses
    /// and sends the JPEG back; or sends a descriptive `screenshotError` so the iPad
    /// can dismiss its spinner and show a useful message.
    private func handleScreenshotRequest(handle: LoomConnectionHandle) async {
        // 1. Check permission — macOS 11+ only
        if #available(macOS 11.0, *) {
            guard CGPreflightScreenCaptureAccess() else {
                // Trigger the system prompt so it appears on next tap (no-op if already denied)
                CGRequestScreenCaptureAccess()
                await sendError(to: handle,
                                message: "Screen Recording permission required. Please allow MirageControl in System Settings > Privacy & Security > Screen Recording, then try again.")
                return
            }
        }

        // 2. Capture the raw CGImage on the main thread (CGDisplayCreateImage is cheap)
        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else {
            await sendError(to: handle, message: "Display capture failed. No displays found.")
            return
        }

        // 3. Resize + JPEG compress on a background thread so we never block the main actor
        let jpegData: Data? = await Task.detached(priority: .userInitiated) {
            let targetWidth = min(CGFloat(cgImage.width), 1920)
            let ratio = targetWidth / CGFloat(cgImage.width)
            let targetSize = NSSize(width: targetWidth, height: CGFloat(cgImage.height) * ratio)

            let resized = NSImage(size: targetSize)
            resized.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSBitmapImageRep(cgImage: cgImage).draw(in: NSRect(origin: .zero, size: targetSize))
            resized.unlockFocus()

            guard let tiff = resized.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        }.value

        guard let data = jpegData else {
            await sendError(to: handle, message: "Image compression failed.")
            return
        }

        // 4. Send the screenshot data back to the iPad
        try? await handle.send(try JSONEncoder().encode(ControlMessage.screenshotData(data: data)))
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

    func removeConnection(id: UUID) {
        connectionTasks[id]?.cancel()
        connectionTasks.removeValue(forKey: id)
        ActiveAppMonitor.shared.removeConnection(id: id)
    }
}

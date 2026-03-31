//
//  ControlReceiver.swift
//  MirageControlMac
//

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
            await self?.consumeMessages(from: connectionHandle)
            _ = await MainActor.run { [weak self] in
                self?.connectionTasks.removeValue(forKey: taskKey)
            }
        }
    }

    private func consumeMessages(from connectionHandle: LoomConnectionHandle) async {
        for await data in connectionHandle.messages {
            guard let message = try? JSONDecoder().decode(ControlMessage.self, from: data) else {
                continue
            }
            await dispatch(message)
        }
    }

    private func dispatch(_ message: ControlMessage) async {
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
            
        case .authorizationStatus:
            // Client-bound message; host doesn't process it locally
            break
        }
    }

    private func dispatchMacro(id: String) async {
        if let item = MacroItem.defaultDeck.first(where: { $0.id == id }) {
            switch item {
            case .app(let app):
                await launcher.launch(bundleID: app.bundleID)
            case .shortcut(let s):
                injector.sendShortcut(keys: s.keys)
            }
        }
    }

    func removeConnection(id: UUID) {
        connectionTasks[id]?.cancel()
        connectionTasks.removeValue(forKey: id)
    }
}

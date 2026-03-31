//
//  ControlMessage.swift
//  MirageControl – Shared
//

import Foundation

// MARK: - Top-level message envelope

public enum ControlMessage: Codable, Sendable {
    case mouseDelta(dx: Float, dy: Float)
    case mouseScroll(dx: Float, dy: Float)
    case mouseClick(button: MouseButton)
    case mouseDoubleClick(button: MouseButton)
    case keyboardShortcut(keys: [String])
    case launchApp(bundleID: String)
    case macroButton(id: String)
    case authorizationStatus(status: String)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, dx, dy, button, keys, bundleID, id, status
    }

    private enum MessageType: String, Codable {
        case mouseDelta, mouseScroll, mouseClick, mouseDoubleClick
        case keyboardShortcut, launchApp, macroButton, authorizationStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(MessageType.self, forKey: .type)
        switch type {
        case .mouseDelta:
            self = .mouseDelta(dx: try c.decode(Float.self, forKey: .dx),
                               dy: try c.decode(Float.self, forKey: .dy))
        case .mouseScroll:
            self = .mouseScroll(dx: try c.decode(Float.self, forKey: .dx),
                                dy: try c.decode(Float.self, forKey: .dy))
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
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .mouseDelta(dx, dy):
            try c.encode(MessageType.mouseDelta, forKey: .type)
            try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case let .mouseScroll(dx, dy):
            try c.encode(MessageType.mouseScroll, forKey: .type)
            try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
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
        }
    }
}

// MARK: - Supporting types

public enum MouseButton: String, Codable, Sendable {
    case left, right, middle
}

//
//  AppShortcut.swift
//  MirageControl – Shared
//

import Foundation

public struct AppShortcut: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let bundleID: String
    public let sfSymbol: String

    public init(id: String, displayName: String, bundleID: String, sfSymbol: String) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.sfSymbol = sfSymbol
    }
}

public struct SystemShortcut: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let sfSymbol: String
    public let keys: [String]

    public init(id: String, displayName: String, sfSymbol: String, keys: [String]) {
        self.id = id
        self.displayName = displayName
        self.sfSymbol = sfSymbol
        self.keys = keys
    }
}

public struct MediaAction: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let sfSymbol: String
    public let action: String

    public init(id: String, displayName: String, sfSymbol: String, action: String) {
        self.id = id
        self.displayName = displayName
        self.sfSymbol = sfSymbol
        self.action = action
    }
}

public enum MacroItem: Identifiable, Codable, Hashable, Sendable {
    case app(AppShortcut)
    case shortcut(SystemShortcut)
    case media(MediaAction)

    public var id: String {
        switch self {
        case .app(let a): "app-\(a.id)"
        case .shortcut(let s): "shortcut-\(s.id)"
        case .media(let m): "media-\(m.id)"
        }
    }

    public var displayName: String {
        switch self {
        case .app(let a): a.displayName
        case .shortcut(let s): s.displayName
        case .media(let m): m.displayName
        }
    }

    public var sfSymbol: String {
        switch self {
        case .app(let a): a.sfSymbol
        case .shortcut(let s): s.sfSymbol
        case .media(let m): m.sfSymbol
        }
    }

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum ItemType: String, Codable { case app, shortcut, media }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(ItemType.self, forKey: .type)
        switch type {
        case .app: self = .app(try c.decode(AppShortcut.self, forKey: .payload))
        case .shortcut: self = .shortcut(try c.decode(SystemShortcut.self, forKey: .payload))
        case .media: self = .media(try c.decode(MediaAction.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let a):
            try c.encode(ItemType.app, forKey: .type)
            try c.encode(a, forKey: .payload)
        case .shortcut(let s):
            try c.encode(ItemType.shortcut, forKey: .type)
            try c.encode(s, forKey: .payload)
        case .media(let m):
            try c.encode(ItemType.media, forKey: .type)
            try c.encode(m, forKey: .payload)
        }
    }
}

// MARK: - Default deck layout

public extension MacroItem {
    static let defaultDeck: [MacroItem] = [
        .app(.init(id: "safari",    displayName: "Safari",    bundleID: "com.apple.Safari",                  sfSymbol: "safari")),
        .app(.init(id: "finder",    displayName: "Finder",    bundleID: "com.apple.finder",                  sfSymbol: "folder")),
        .app(.init(id: "terminal",  displayName: "Terminal",  bundleID: "com.apple.Terminal",                sfSymbol: "terminal")),
        .app(.init(id: "vscode",    displayName: "VS Code",   bundleID: "com.microsoft.VSCode",              sfSymbol: "curlybraces")),
        .app(.init(id: "xcode",     displayName: "Xcode",     bundleID: "com.apple.dt.Xcode",                sfSymbol: "hammer")),
        .app(.init(id: "slack",     displayName: "Slack",     bundleID: "com.tinyspeck.slackmacgap",         sfSymbol: "bubble.left.and.bubble.right")),
        .app(.init(id: "mail",      displayName: "Mail",      bundleID: "com.apple.mail",                    sfSymbol: "envelope")),
        .app(.init(id: "calendar",  displayName: "Calendar",  bundleID: "com.apple.iCal",                    sfSymbol: "calendar")),
        .shortcut(.init(id: "missioncontrol", displayName: "Mission Control", sfSymbol: "square.grid.2x2",   keys: ["ctrl", "up"])),
        .shortcut(.init(id: "launchpad",      displayName: "Launchpad",       sfSymbol: "circle.grid.3x3",   keys: ["cmd", "space"])),
        .shortcut(.init(id: "showdesktop",    displayName: "Show Desktop",    sfSymbol: "desktopcomputer",   keys: ["fn", "f11"])),
        .media(.init(id: "prev", displayName: "Previous", sfSymbol: "backward.end.fill", action: "prev")),
        .media(.init(id: "playpause", displayName: "Play/Pause", sfSymbol: "playpause.fill", action: "playpause")),
        .media(.init(id: "next", displayName: "Next", sfSymbol: "forward.end.fill", action: "next"))
    ]
}

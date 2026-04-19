//
//  AppShortcutBinding.swift
//  MirageControl – Shared
//

import Foundation

/// One keyboard shortcut bound to a specific macOS application.
///
/// These are declared iPad-side (either from `CuratedShortcuts` or created by
/// the user) and sent to the Mac via `ControlMessage.appShortcut`. The Mac
/// activates `bundleID`, waits for it to become frontmost, then injects the
/// key sequence through `InputInjector`.
public struct AppShortcutBinding: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let bundleID: String
    public let displayName: String
    public let keys: [String]
    public let sfSymbol: String
    /// `true` for bindings that ship in `CuratedShortcuts`. Users can hide
    /// curated bindings but cannot edit them — the UI offers a "Duplicate &
    /// Edit" affordance instead.
    public let isCurated: Bool

    public init(
        id: String = UUID().uuidString,
        bundleID: String,
        displayName: String,
        keys: [String],
        sfSymbol: String = "keyboard",
        isCurated: Bool = false
    ) {
        self.id = id
        self.bundleID = bundleID
        self.displayName = displayName
        self.keys = keys
        self.sfSymbol = sfSymbol
        self.isCurated = isCurated
    }

    /// Human-readable rendering (e.g. `⌘⇧P`) for the UI. Uses macOS glyphs
    /// for the standard modifier keys and uppercases everything else.
    public var keyGlyphs: String {
        var modifiers = ""
        var literal = ""
        for raw in keys {
            switch raw.lowercased() {
            case "cmd", "command": modifiers += "⌘"
            case "shift":          modifiers += "⇧"
            case "option", "alt":  modifiers += "⌥"
            case "ctrl", "control":modifiers += "⌃"
            case "fn":             modifiers += "fn"
            case "space":          literal += "␣"
            case "return", "enter":literal += "⏎"
            case "tab":            literal += "⇥"
            case "escape", "esc":  literal += "⎋"
            case "delete", "backspace": literal += "⌫"
            case "up":             literal += "↑"
            case "down":           literal += "↓"
            case "left":           literal += "←"
            case "right":          literal += "→"
            default:               literal += raw.uppercased()
            }
        }
        return modifiers + literal
    }
}

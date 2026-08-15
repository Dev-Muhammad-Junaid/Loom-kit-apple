//
//  AppShortcutBinding.swift
//  Deck Hand – Shared
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
    /// Top-level menu the binding was discovered under (e.g. `"Window"`,
    /// `"Help"`, `"File"`). `nil` for curated and user-authored entries that
    /// aren't tied to a specific menu. Used by the iPad UI to section
    /// imported shortcuts and collapse system-ish categories.
    public let category: String?

    public init(
        id: String = UUID().uuidString,
        bundleID: String,
        displayName: String,
        keys: [String],
        sfSymbol: String = "keyboard",
        isCurated: Bool = false,
        category: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.displayName = displayName
        self.keys = keys
        self.sfSymbol = sfSymbol
        self.isCurated = isCurated
        self.category = category
    }

    /// `displayName` with the leading `Category › ` prefix stripped. Falls
    /// back to the full name if no prefix is present. Useful when the UI
    /// already shows the category as a section header.
    public var shortDisplayName: String {
        guard let range = displayName.range(of: " › ") else { return displayName }
        return String(displayName[range.upperBound...])
    }

    /// Returns the binding's `category`, falling back to the leading segment
    /// of its `displayName` (`"Window"` from `"Window › Center"`). Lets the
    /// iPad group shortcuts that were imported *before* we started storing
    /// the field explicitly.
    public var effectiveCategory: String? {
        if let category, !category.isEmpty { return category }
        guard let range = displayName.range(of: " › ") else { return nil }
        return String(displayName[..<range.lowerBound])
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

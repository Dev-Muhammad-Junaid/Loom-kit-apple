//
//  CuratedShortcuts.swift
//  MirageControl – Shared
//
//  Built-in preset bindings so the user has a useful deck the moment they
//  connect for the first time. IDs are deterministic (`curated.<bundleID>.<slug>`)
//  so the iOS `ShortcutStore` can hide individual presets without losing the
//  identity across upgrades.
//

import Foundation

public enum CuratedShortcuts {
    /// Returns curated bindings for `bundleID`, or an empty array if we don't
    /// ship a preset library for that app yet.
    public static func bindings(for bundleID: String) -> [AppShortcutBinding] {
        library[bundleID] ?? []
    }

    /// All bundle IDs we have curated content for — useful when the iOS side
    /// wants to show a "Presets available" badge.
    public static var curatedBundleIDs: Set<String> { Set(library.keys) }

    // MARK: - Library

    private static let library: [String: [AppShortcutBinding]] = [
        // ── Safari ─────────────────────────────────────────────
        "com.apple.Safari": [
            .preset("safari", "new-tab",            "New Tab",          ["cmd", "t"],                 "plus.square"),
            .preset("safari", "close-tab",          "Close Tab",        ["cmd", "w"],                 "xmark.square"),
            .preset("safari", "reopen-closed-tab",  "Reopen Closed",    ["cmd", "shift", "t"],        "arrow.uturn.backward"),
            .preset("safari", "reader",             "Reader Mode",      ["cmd", "shift", "r"],        "doc.text"),
            .preset("safari", "focus-url",          "Focus URL Bar",    ["cmd", "l"],                 "magnifyingglass"),
            .preset("safari", "find",               "Find on Page",     ["cmd", "f"],                 "text.magnifyingglass"),
            .preset("safari", "next-tab",           "Next Tab",         ["ctrl", "tab"],              "chevron.right"),
            .preset("safari", "prev-tab",           "Previous Tab",     ["ctrl", "shift", "tab"],     "chevron.left"),
            .preset("safari", "downloads",          "Downloads",        ["cmd", "option", "l"],       "arrow.down.circle"),
            .preset("safari", "private-window",     "Private Window",   ["cmd", "shift", "n"],        "eyeglasses"),
        ],

        // ── Cursor ─────────────────────────────────────────────
        "com.todesktop.230313mzl4w4u92": [  // Cursor's actual bundle ID
            .preset("cursor", "command-palette",    "Command Palette",  ["cmd", "shift", "p"],        "command.circle"),
            .preset("cursor", "quick-open",         "Quick Open",       ["cmd", "p"],                 "doc.text.magnifyingglass"),
            .preset("cursor", "toggle-sidebar",     "Toggle Sidebar",   ["cmd", "b"],                 "sidebar.left"),
            .preset("cursor", "toggle-terminal",    "Toggle Terminal",  ["cmd", "`"],                 "terminal"),
            .preset("cursor", "ai-chat",            "AI Chat",          ["cmd", "l"],                 "sparkles"),
            .preset("cursor", "ai-compose",         "AI Compose",       ["cmd", "i"],                 "text.badge.plus"),
            .preset("cursor", "inline-edit",        "Inline Edit",      ["cmd", "k"],                 "wand.and.stars"),
            .preset("cursor", "find",               "Find",             ["cmd", "f"],                 "magnifyingglass"),
            .preset("cursor", "find-in-files",      "Find in Files",    ["cmd", "shift", "f"],        "text.magnifyingglass"),
            .preset("cursor", "split-editor",       "Split Editor",     ["cmd", "\\"],                "rectangle.split.2x1"),
        ],

        // ── VS Code ────────────────────────────────────────────
        "com.microsoft.VSCode": [
            .preset("vscode", "command-palette",    "Command Palette",  ["cmd", "shift", "p"],        "command.circle"),
            .preset("vscode", "quick-open",         "Quick Open",       ["cmd", "p"],                 "doc.text.magnifyingglass"),
            .preset("vscode", "toggle-sidebar",     "Toggle Sidebar",   ["cmd", "b"],                 "sidebar.left"),
            .preset("vscode", "toggle-terminal",    "Toggle Terminal",  ["cmd", "`"],                 "terminal"),
            .preset("vscode", "find",               "Find",             ["cmd", "f"],                 "magnifyingglass"),
            .preset("vscode", "find-in-files",      "Find in Files",    ["cmd", "shift", "f"],        "text.magnifyingglass"),
            .preset("vscode", "split-editor",       "Split Editor",     ["cmd", "\\"],                "rectangle.split.2x1"),
            .preset("vscode", "format",             "Format Document",  ["option", "shift", "f"],     "text.alignleft"),
        ],

        // ── Xcode ──────────────────────────────────────────────
        "com.apple.dt.Xcode": [
            .preset("xcode", "build",               "Build",            ["cmd", "b"],                 "hammer"),
            .preset("xcode", "run",                 "Run",              ["cmd", "r"],                 "play.fill"),
            .preset("xcode", "stop",                "Stop",             ["cmd", "."],                 "stop.fill"),
            .preset("xcode", "clean",               "Clean Build",      ["cmd", "shift", "k"],        "trash"),
            .preset("xcode", "open-quickly",        "Open Quickly",     ["cmd", "shift", "o"],        "doc.text.magnifyingglass"),
            .preset("xcode", "find-in-workspace",   "Find in Workspace",["cmd", "shift", "f"],        "text.magnifyingglass"),
            .preset("xcode", "toggle-navigator",    "Navigator",        ["cmd", "0"],                 "sidebar.left"),
            .preset("xcode", "toggle-inspector",    "Inspector",        ["cmd", "option", "0"],       "sidebar.right"),
            .preset("xcode", "toggle-debug",        "Debug Area",       ["cmd", "shift", "y"],        "ladybug"),
        ],

        // ── Finder ─────────────────────────────────────────────
        "com.apple.finder": [
            .preset("finder", "new-window",         "New Window",       ["cmd", "n"],                 "plus.square"),
            .preset("finder", "new-folder",         "New Folder",       ["cmd", "shift", "n"],        "folder.badge.plus"),
            .preset("finder", "get-info",           "Get Info",         ["cmd", "i"],                 "info.circle"),
            .preset("finder", "go-applications",    "Applications",     ["cmd", "shift", "a"],        "square.grid.2x2"),
            .preset("finder", "go-home",            "Home",             ["cmd", "shift", "h"],        "house"),
            .preset("finder", "go-downloads",       "Downloads",        ["cmd", "option", "l"],       "arrow.down.circle"),
            .preset("finder", "toggle-hidden",      "Toggle Hidden",    ["cmd", "shift", "."],        "eye"),
            .preset("finder", "go-to-folder",       "Go to Folder",     ["cmd", "shift", "g"],        "folder"),
        ],

        // ── Terminal ───────────────────────────────────────────
        "com.apple.Terminal": [
            .preset("terminal", "new-tab",          "New Tab",          ["cmd", "t"],                 "plus.square"),
            .preset("terminal", "new-window",       "New Window",       ["cmd", "n"],                 "macwindow.badge.plus"),
            .preset("terminal", "clear",            "Clear",            ["cmd", "k"],                 "trash"),
            .preset("terminal", "split",            "Split Pane",       ["cmd", "d"],                 "rectangle.split.2x1"),
            .preset("terminal", "close-tab",        "Close Tab",        ["cmd", "w"],                 "xmark.square"),
        ],

        // ── Mail ───────────────────────────────────────────────
        "com.apple.mail": [
            .preset("mail", "new",                  "New Message",      ["cmd", "n"],                 "square.and.pencil"),
            .preset("mail", "reply",                "Reply",            ["cmd", "r"],                 "arrowshape.turn.up.left"),
            .preset("mail", "reply-all",            "Reply All",        ["cmd", "shift", "r"],        "arrowshape.turn.up.left.2"),
            .preset("mail", "forward",              "Forward",          ["cmd", "shift", "f"],        "arrowshape.turn.up.right"),
            .preset("mail", "archive",              "Archive",          ["ctrl", "cmd", "a"],         "archivebox"),
            .preset("mail", "mark-read",            "Mark Read/Unread", ["cmd", "shift", "u"],        "envelope.open"),
        ],

        // ── Google Chrome ──────────────────────────────────────
        "com.google.Chrome": [
            .preset("chrome", "new-tab",           "New Tab",           ["cmd", "t"],            "plus.square"),
            .preset("chrome", "close-tab",         "Close Tab",         ["cmd", "w"],            "xmark.square"),
            .preset("chrome", "reopen-closed",     "Reopen Closed",     ["cmd", "shift", "t"],   "arrow.uturn.backward"),
            .preset("chrome", "new-window",        "New Window",        ["cmd", "n"],            "macwindow.badge.plus"),
            .preset("chrome", "incognito",         "Incognito Window",  ["cmd", "shift", "n"],   "eyeglasses"),
            .preset("chrome", "focus-url",         "Focus URL Bar",     ["cmd", "l"],            "magnifyingglass"),
            .preset("chrome", "find",              "Find on Page",      ["cmd", "f"],            "text.magnifyingglass"),
            .preset("chrome", "next-tab",          "Next Tab",          ["cmd", "option", "right"], "chevron.right"),
            .preset("chrome", "prev-tab",          "Previous Tab",      ["cmd", "option", "left"],  "chevron.left"),
            .preset("chrome", "reload",            "Reload",            ["cmd", "r"],            "arrow.clockwise"),
            .preset("chrome", "hard-reload",       "Hard Reload",       ["cmd", "shift", "r"],   "arrow.triangle.2.circlepath"),
            .preset("chrome", "devtools",          "Developer Tools",   ["cmd", "option", "i"],  "wrench.and.screwdriver"),
            .preset("chrome", "downloads",         "Downloads",         ["cmd", "shift", "j"],   "arrow.down.circle"),
            .preset("chrome", "history",           "History",           ["cmd", "y"],            "clock.arrow.circlepath"),
            .preset("chrome", "bookmarks",         "Bookmarks",         ["cmd", "option", "b"],  "book"),
        ],

        // ── Slack ──────────────────────────────────────────────
        "com.tinyspeck.slackmacgap": [
            .preset("slack", "quick-switch",        "Quick Switcher",   ["cmd", "k"],                 "arrow.left.arrow.right"),
            .preset("slack", "next-unread",         "Next Unread",      ["option", "shift", "down"],  "chevron.down.circle"),
            .preset("slack", "prev-unread",         "Previous Unread",  ["option", "shift", "up"],    "chevron.up.circle"),
            .preset("slack", "threads",              "Threads",         ["cmd", "shift", "t"],        "bubble.left.and.bubble.right"),
            .preset("slack", "toggle-sidebar",      "Toggle Sidebar",   ["cmd", "shift", "d"],        "sidebar.left"),
            .preset("slack", "mark-all-read",       "Mark All Read",    ["cmd", "shift", "escape"],   "checkmark.circle"),
        ],
    ]
}

// MARK: - Internal helper

private extension AppShortcutBinding {
    static func preset(
        _ appSlug: String,
        _ actionSlug: String,
        _ displayName: String,
        _ keys: [String],
        _ sfSymbol: String
    ) -> AppShortcutBinding {
        AppShortcutBinding(
            id: "curated.\(appSlug).\(actionSlug)",
            bundleID: bundleID(forAppSlug: appSlug),
            displayName: displayName,
            keys: keys,
            sfSymbol: sfSymbol,
            isCurated: true
        )
    }

    /// Reverse map so curated entries stay readable without repeating bundle
    /// IDs on every line above. Kept private to the file.
    static func bundleID(forAppSlug slug: String) -> String {
        switch slug {
        case "safari":   "com.apple.Safari"
        case "cursor":   "com.todesktop.230313mzl4w4u92"
        case "vscode":   "com.microsoft.VSCode"
        case "xcode":    "com.apple.dt.Xcode"
        case "finder":   "com.apple.finder"
        case "terminal": "com.apple.Terminal"
        case "mail":     "com.apple.mail"
        case "slack":    "com.tinyspeck.slackmacgap"
        case "chrome":   "com.google.Chrome"
        default:         slug
        }
    }
}

//
//  QuickActionsBar.swift
//  MirageControliOS
//
//  Horizontally-scrolling, context-aware strip that takes the place of the
//  old static "QUICK ACTIONS" grid. Inspired by Xcode's Touch Bar: content
//  morphs as the Mac's frontmost app changes, so what you see always maps
//  to what's happening on the other end.
//
//  Segments (left → right):
//    1. App context pill — icon + name of the frontmost Mac app. Tap opens
//       the full shortcuts sheet for that app.
//    2. App-contextual chips — top shortcuts for `activeBundleID` (curated
//       ∪ custom, minus hidden) pulled from `ShortcutStore`. Empty state
//       offers an inline "Add shortcuts" CTA.
//    3. Global macros — Mission Control, Launchpad, Show Desktop.
//    4. Media transport — previous / play-pause / next.
//

import SwiftUI
import UIKit

/// Which auxiliary chip row the floating FABs surface in the Quick Actions
/// contextual segment. Keyboard FAB ↔ text editing; numpad FAB ↔ digits.
enum EditFABMode: String, Equatable, Sendable {
    case hidden
    case textEditing
    case numericKeypad
}

struct QuickActionsBar: View {
    let sender: TrackpadSender
    let colorScheme: ColorScheme
    let installedApps: [InstalledAppInfo]
    let activeBundleID: String?
    /// Running apps on the Mac in Cmd+Tab order (most-recently-activated
    /// first). Drives the app-switcher menu next to the app pill.
    let runningBundleIDs: [String]
    /// AX-derived snapshot of what's currently interactable on the Mac.
    /// When this carries a `.dialog(...)`, the middle segment swaps from
    /// per-app shortcut chips to the dialog's buttons.
    let uiContext: UIContextSnapshot
    /// Which extra row (if any) is shown after the app shortcut chips.
    /// Seeded from AX and flipped by the two floating FABs in
    /// `StreamDeckGridView`. Mutually exclusive: only one auxiliary row
    /// at a time.
    let editFABMode: EditFABMode
    /// Invoked when the user taps the app pill, or the "Add shortcuts" CTA
    /// in the empty middle segment. Parent is responsible for presenting
    /// `AppShortcutsSheet`.
    let onOpenAppSheet: (InstalledAppInfo) -> Void

    @ObservedObject private var store = ShortcutStore.shared

    /// How many app-contextual shortcut chips to surface inline before the
    /// user has to open the sheet. Six feels right at ~iPad width; the rest
    /// are reachable via tapping the app pill.
    private let maxContextualChips = 6

    private var activeApp: InstalledAppInfo? {
        guard let bundleID = activeBundleID else { return nil }
        return installedApps.first(where: { $0.bundleID == bundleID })
    }

    private var contextualBindings: [AppShortcutBinding] {
        guard let bundleID = activeBundleID else { return [] }
        // Compress the per-app shortcut slot when a text field is also being
        // surfaced — so a Chrome user keeps quick access to e.g. New Tab
        // while also seeing Cut / Copy / Paste in the same row.
        let cap = hasAuxiliaryEditRow ? 3 : maxContextualChips
        return Array(store.bindings(for: bundleID).prefix(cap))
    }

    /// True when either the text-edit row or the numpad row is visible.
    private var hasAuxiliaryEditRow: Bool {
        editFABMode != .hidden
    }

    /// Kind for the Cut/Copy/Paste row — only when `editFABMode` is
    /// `.textEditing`. AX classification refines secure vs text; manual
    /// activation with no AX field defaults to `.text`.
    private var textEditRowKind: TextFieldContext.Kind? {
        guard editFABMode == .textEditing else { return nil }
        if case .textField(let ctx) = uiContext { return ctx.kind }
        return .text
    }

    private var showNumericKeypad: Bool {
        editFABMode == .numericKeypad
    }

    /// Running apps the user can switch to, excluding whichever one is already
    /// frontmost. Resolved against `installedApps` so we have icons + names.
    private var otherRunningApps: [InstalledAppInfo] {
        let lookup = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.bundleID, $0) })
        return runningBundleIDs.compactMap { bundleID -> InstalledAppInfo? in
            guard bundleID != activeBundleID else { return nil }
            return lookup[bundleID]
        }
    }

    var body: some View {
        Group {
            if case .dialog(let ctx) = uiContext {
                // Takeover layout — mirrors how Apple's Touch Bar went
                // "all-hands" for NSAlerts: static macros/media hide so
                // the dialog's message + buttons get the full width.
                dialogTakeoverBar(ctx)
                    .id("takeover-\(ctx.revision)")
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .center)),
                        removal: .opacity
                    ))
            } else {
                normalBar
                    .transition(.opacity)
            }
        }
        .frame(height: 64)
        .background(barBackground)
        .clipShape(RoundedRectangle(cornerRadius: MirageTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MirageTheme.Radius.md, style: .continuous)
                .strokeBorder(MirageTheme.tabContainerBorder(colorScheme), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: activeBundleID)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isDialogActive)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: editFABMode)
    }

    /// `true` while the Mac is reporting an active modal dialog/sheet. Drives
    /// the full-width takeover layout.
    private var isDialogActive: Bool {
        if case .dialog = uiContext { return true }
        return false
    }

    private var normalBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                appContextSegment
                segmentDivider
                contextualSegment
                segmentDivider
                globalSegment
                segmentDivider
                mediaSegment
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func dialogTakeoverBar(_ ctx: DialogContext) -> some View {
        HStack(spacing: 10) {
            appContextSegment
            segmentDivider
            DialogInfoButton(title: ctx.title, message: ctx.message, colorScheme: colorScheme)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ForEach(ctx.buttons) { button in
                    DialogButtonChip(button: button, colorScheme: colorScheme) {
                        UIImpactFeedbackGenerator(
                            style: button.isDefault ? .medium : .light
                        ).impactOccurred()
                        Task { await sender.sendContextAction(id: button.id) }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Segments

    @ViewBuilder
    private var appContextSegment: some View {
        HStack(spacing: 2) {
            if let app = activeApp {
                AppContextPill(app: app, colorScheme: colorScheme) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onOpenAppSheet(app)
                }
                .id("pill-\(app.bundleID)")
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                IdlePill(colorScheme: colorScheme)
                    .transition(.opacity)
            }

            if !otherRunningApps.isEmpty {
                AppSwitcherMenu(apps: otherRunningApps, colorScheme: colorScheme) { app in
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await sender.sendLaunchApp(app.bundleID) }
                }
            }
        }
    }

    // The contextual middle segment is only used in the normal (non-dialog)
    // layout — the takeover bar renders dialog content in its own path.
    //
    // Layout policy:
    //   • App shortcuts are ALWAYS shown (up to `maxContextualChips`), even
    //     when a text field is focused — just compressed to 3 so the row
    //     stays reasonable. This is the "append, don't replace" rule that
    //     lets users in Chrome / Cursor / Slack etc. keep flipping between
    //     app commands and edit actions without losing either side.
    //   • When AX surfaced a focused text/numeric/secure field, the edit
    //     chips are appended after a thin divider.
    @ViewBuilder
    private var contextualSegment: some View {
        HStack(spacing: 8) {
            shortcutChipsSegment
                .id("ctx-\(activeBundleID ?? "none")")

            if showNumericKeypad {
                chipDivider
                numpadChips
                    .id("numpad-row")
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else if let kind = textEditRowKind {
                chipDivider
                textFieldChips(kind)
                    .id("textfield-\(kind.rawValue)")
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
    }

    private var numpadChips: some View {
        HStack(spacing: 5) {
            ForEach(NumpadAction.all) { key in
                NumpadChip(key: key, colorScheme: colorScheme) {
                    UIImpactFeedbackGenerator(
                        style: key.isPrimary ? .medium : .light
                    ).impactOccurred()
                    Task { await sender.sendShortcut(key.keys) }
                }
            }
        }
    }

    /// Slim divider rendered inline between the app-shortcut chips and the
    /// text-edit chips when both are present. Shorter than the main
    /// segment divider so the appended section feels tied to the app row.
    private var chipDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(width: 1, height: 24)
    }

    @ViewBuilder
    private var shortcutChipsSegment: some View {
        HStack(spacing: 8) {
            if contextualBindings.isEmpty {
                if let app = activeApp {
                    AddShortcutsChip(appName: app.displayName, colorScheme: colorScheme) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onOpenAppSheet(app)
                    }
                } else {
                    PlaceholderChip(text: "Focus an app on your Mac",
                                    systemImage: "dot.radiowaves.left.and.right",
                                    colorScheme: colorScheme)
                }
            } else {
                ForEach(contextualBindings) { binding in
                    ShortcutChip(binding: binding, colorScheme: colorScheme) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task {
                            await sender.sendAppShortcut(
                                bundleID: binding.bundleID,
                                keys: binding.keys
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func textFieldChips(_ kind: TextFieldContext.Kind) -> some View {
        HStack(spacing: 6) {
            ForEach(TextFieldAction.actions(for: kind)) { action in
                TextFieldChip(action: action, colorScheme: colorScheme) {
                    UIImpactFeedbackGenerator(
                        style: action.isPrimary ? .medium : .light
                    ).impactOccurred()
                    Task { await sender.sendShortcut(action.keys) }
                }
            }
        }
    }

    private var globalSegment: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "macwindow.on.rectangle", colorScheme: colorScheme) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await sender.sendMacro("missioncontrol_trigger") }
            }
            IconButton(symbol: "square.grid.3x3.fill", colorScheme: colorScheme) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await sender.sendMacro("launchpad_trigger") }
            }
            IconButton(symbol: "macwindow", colorScheme: colorScheme) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await sender.sendMacro("showdesktop") }
            }
        }
    }

    private var mediaSegment: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "backward.fill", colorScheme: colorScheme) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await sender.sendMediaAction("prev") }
            }
            IconButton(symbol: "playpause.fill", colorScheme: colorScheme) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await sender.sendMediaAction("playpause") }
            }
            IconButton(symbol: "forward.fill", colorScheme: colorScheme) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await sender.sendMediaAction("next") }
            }
        }
    }

    // MARK: - Chrome

    private var segmentDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(width: 1, height: 28)
    }

    private var barBackground: some View {
        MirageTheme.tabContainerFill(colorScheme)
    }
}

// MARK: - App Context Pill

private struct AppContextPill: View {
    let app: InstalledAppInfo
    let colorScheme: ColorScheme
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                icon.frame(width: 28, height: 28)
                Text(app.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(minWidth: 52)
            .padding(.horizontal, 4)
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }

    @ViewBuilder
    private var icon: some View {
        if let data = app.iconData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(MirageTheme.subtleWellFill(colorScheme))
                .overlay(
                    Image(systemName: "app")
                        .font(.system(size: 13, weight: .thin))
                        .foregroundStyle(Color.primary.opacity(0.4))
                )
        }
    }
}

// MARK: - Idle Pill (no active app yet)

private struct IdlePill: View {
    let colorScheme: ColorScheme

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "app.dashed")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .frame(width: 28, height: 28)
            Text("No app")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.6))
        }
        .frame(minWidth: 52)
        .padding(.horizontal, 4)
    }
}

// MARK: - Shortcut Chip (contextual — label + glyph)

private struct ShortcutChip: View {
    let binding: AppShortcutBinding
    let colorScheme: ColorScheme
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text(binding.keyGlyphs)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(binding.displayName)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 56)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MirageTheme.subtleWellFill(colorScheme))
            )
            .scaleEffect(isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}

// MARK: - Add Shortcuts CTA (empty contextual segment)

private struct AddShortcutsChip: View {
    let appName: String
    let colorScheme: ColorScheme
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Text("Add shortcuts")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PlaceholderChip: View {
    let text: String
    let systemImage: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary.opacity(0.5))
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Keyboard FAB

/// Floating circular toggle that force-enables the edit-chip row in the
/// Quick Actions bar. Use when AX didn't surface a focused text field —
/// common in Chromium / Electron apps and custom-drawn controls.
/// Visibility is owned by the parent (StreamDeckGridView) which hides it
/// when a dialog or AX-detected text field is already active.
struct KeyboardFAB: View {
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        FABButton(
            systemImage: "keyboard",
            isActive: isActive,
            tint: MirageTheme.FAB.keyboardTint,
            accessibilityLabel: isActive ? "Hide text edit actions"
                                         : "Show text edit actions",
            onTap: onTap
        )
    }
}

// MARK: - Numeric FAB

/// Floating toggle for the digit row in the Quick Actions bar. Mutually
/// exclusive with `KeyboardFAB` — the parent flips `EditFABMode` so only
/// one auxiliary row is visible at a time.
struct NumericFAB: View {
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        FABButton(
            systemImage: "textformat.123",
            isActive: isActive,
            tint: MirageTheme.FAB.numericTint,
            accessibilityLabel: isActive ? "Hide number keys"
                                         : "Show number keys",
            onTap: onTap
        )
    }
}

// MARK: - Shared FAB renderer
//
// `KeyboardFAB` and `NumericFAB` are thin shells around a native `Button`
// circular toggle. The actual visual treatment comes from the system:
// iOS 26+ uses Liquid Glass via `.glass` / `.glassProminent`; iOS 17
// falls back to `.bordered` / `.borderedProminent`. Either way, geometry,
// shadow, and press animations are handled by the platform — we only
// pick the icon and the active tint.

private struct FABButton: View {
    let systemImage: String
    let isActive: Bool
    let tint: Color
    let accessibilityLabel: String
    let onTap: () -> Void

    var body: some View {
        nativeButton
            .buttonBorderShape(.circle)
            .controlSize(.extraLarge)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var nativeButton: some View {
        if #available(iOS 26.0, *) {
            if isActive {
                Button(action: onTap) { icon }
                    .buttonStyle(.glassProminent)
                    .tint(tint)
            } else {
                Button(action: onTap) { icon }
                    .buttonStyle(.glass)
            }
        } else {
            if isActive {
                Button(action: onTap) { icon }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            } else {
                Button(action: onTap) { icon }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
    }
}

// MARK: - Text Field Actions

/// One chip in the text/numeric editing row.
private struct TextFieldAction: Identifiable {
    let id: String
    let symbol: String
    let label: String
    let keys: [String]
    let isPrimary: Bool  // Return — violet-filled like the default dialog button

    static func actions(for kind: TextFieldContext.Kind) -> [TextFieldAction] {
        switch kind {
        case .text:
            return [
                .init(id: "cut",       symbol: "scissors",             label: "Cut",    keys: ["cmd", "x"],          isPrimary: false),
                .init(id: "copy",      symbol: "doc.on.doc",           label: "Copy",   keys: ["cmd", "c"],          isPrimary: false),
                .init(id: "paste",     symbol: "doc.on.clipboard",     label: "Paste",  keys: ["cmd", "v"],          isPrimary: false),
                .init(id: "undo",      symbol: "arrow.uturn.backward", label: "Undo",   keys: ["cmd", "z"],          isPrimary: false),
                .init(id: "redo",      symbol: "arrow.uturn.forward",  label: "Redo",   keys: ["cmd", "shift", "z"], isPrimary: false),
                .init(id: "selectAll", symbol: "selection.pin.in.out", label: "All",    keys: ["cmd", "a"],          isPrimary: false),
                .init(id: "delete",    symbol: "delete.left",          label: "Delete", keys: ["delete"],            isPrimary: false),
                .init(id: "return",    symbol: "return",               label: "Return", keys: ["return"],            isPrimary: true),
            ]

        case .numeric:
            return [
                .init(id: "dec",    symbol: "minus",                label: "Dec",    keys: ["down"],     isPrimary: false),
                .init(id: "inc",    symbol: "plus",                 label: "Inc",    keys: ["up"],       isPrimary: false),
                .init(id: "paste",  symbol: "doc.on.clipboard",     label: "Paste",  keys: ["cmd", "v"], isPrimary: false),
                .init(id: "undo",   symbol: "arrow.uturn.backward", label: "Undo",   keys: ["cmd", "z"], isPrimary: false),
                .init(id: "delete", symbol: "delete.left",          label: "Delete", keys: ["delete"],   isPrimary: false),
                .init(id: "return", symbol: "return",               label: "Enter",  keys: ["return"],   isPrimary: true),
            ]

        case .secure:
            // Password fields: macOS blocks cut/copy and many apps will
            // ignore paste too, so keep the row minimal and focused.
            return [
                .init(id: "paste",  symbol: "doc.on.clipboard", label: "Paste",  keys: ["cmd", "v"], isPrimary: false),
                .init(id: "delete", symbol: "delete.left",      label: "Delete", keys: ["delete"],   isPrimary: false),
                .init(id: "return", symbol: "return",           label: "Submit", keys: ["return"],   isPrimary: true),
            ]
        }
    }
}

private struct TextFieldChip: View {
    let action: TextFieldAction
    let colorScheme: ColorScheme
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Image(systemName: action.symbol)
                    .font(.system(size: 13, weight: action.isPrimary ? .semibold : .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(foreground)
                Text(action.label)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(foreground.opacity(action.isPrimary ? 0.9 : 0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .scaleEffect(isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }

    private var foreground: Color {
        action.isPrimary ? .white : Color.primary.opacity(0.85)
    }

    private var background: Color {
        action.isPrimary ? MirageTheme.violet : MirageTheme.subtleWellFill(colorScheme)
    }
}

// MARK: - Numpad

private struct NumpadAction: Identifiable {
    let id: String
    /// Shown under the key glyph (digit or symbol).
    let label: String
    let symbol: String?
    let keys: [String]
    let isPrimary: Bool

    /// Keys 1–9, 0, decimal, minus, delete, return — sent as raw
    /// keyboard events to whatever field is focused on the Mac.
    static let all: [NumpadAction] = [
        .init(id: "1", label: "1", symbol: nil, keys: ["1"], isPrimary: false),
        .init(id: "2", label: "2", symbol: nil, keys: ["2"], isPrimary: false),
        .init(id: "3", label: "3", symbol: nil, keys: ["3"], isPrimary: false),
        .init(id: "4", label: "4", symbol: nil, keys: ["4"], isPrimary: false),
        .init(id: "5", label: "5", symbol: nil, keys: ["5"], isPrimary: false),
        .init(id: "6", label: "6", symbol: nil, keys: ["6"], isPrimary: false),
        .init(id: "7", label: "7", symbol: nil, keys: ["7"], isPrimary: false),
        .init(id: "8", label: "8", symbol: nil, keys: ["8"], isPrimary: false),
        .init(id: "9", label: "9", symbol: nil, keys: ["9"], isPrimary: false),
        .init(id: "0", label: "0", symbol: nil, keys: ["0"], isPrimary: false),
        .init(id: "dot", label: ".", symbol: nil, keys: ["."], isPrimary: false),
        .init(id: "minus", label: "−", symbol: "minus", keys: ["-"], isPrimary: false),
        .init(id: "del", label: "Del", symbol: "delete.left", keys: ["delete"], isPrimary: false),
        .init(id: "ret", label: "Enter", symbol: "return", keys: ["return"], isPrimary: true),
    ]
}

private struct NumpadChip: View {
    let key: NumpadAction
    let colorScheme: ColorScheme
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            Group {
                if let sym = key.symbol {
                    VStack(spacing: 2) {
                        Image(systemName: sym)
                            .font(.system(size: 13, weight: key.isPrimary ? .semibold : .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(foreground)
                        Text(key.label)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(foreground.opacity(0.78))
                            .lineLimit(1)
                    }
                } else {
                    Text(key.label)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(foreground)
                }
            }
            .frame(minWidth: key.symbol == nil ? 34 : 40, minHeight: 36)
            .padding(.horizontal, key.symbol == nil ? 6 : 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .scaleEffect(isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }

    private var foreground: Color {
        key.isPrimary ? .white : Color.primary.opacity(0.85)
    }

    private var background: Color {
        key.isPrimary ? MirageTheme.violet : MirageTheme.subtleWellFill(colorScheme)
    }
}

// MARK: - Dialog Info Button (tap-to-reveal tooltip)

/// Compact violet alert icon shown inside the takeover bar. Tap to pop
/// over the dialog's title + full message, so long AX copy doesn't steal
/// horizontal space from the action buttons. Hidden entirely when AX
/// surfaced neither a title nor a message — in that case the actions
/// alone carry the context.
private struct DialogInfoButton: View {
    let title: String?
    let message: String?
    let colorScheme: ColorScheme

    @State private var showingPopover = false

    private var hasInfo: Bool {
        (title?.isEmpty == false) || (message?.isEmpty == false)
    }

    var body: some View {
        if hasInfo {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showingPopover.toggle()
            } label: {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(MirageTheme.violet)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                DialogInfoPopover(title: title, message: message, colorScheme: colorScheme)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

private struct DialogInfoPopover: View {
    let title: String?
    let message: String?
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
            }
            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
    }
}

// MARK: - Dialog Button Chip

private struct DialogButtonChip: View {
    let button: DialogButton
    let colorScheme: ColorScheme
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(button.title)
                    .font(.system(size: 12, weight: button.isDefault ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                if button.isDefault {
                    Text("⏎")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(foreground.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(stroke, lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }

    private var foreground: Color {
        if button.isDefault { return .white }
        if button.isCancel  { return Color.secondary }
        return Color.primary
    }

    private var background: Color {
        if button.isDefault { return MirageTheme.violet }
        if button.isCancel  { return Color.clear }
        return MirageTheme.subtleWellFill(colorScheme)
    }

    private var stroke: Color {
        if button.isDefault { return MirageTheme.violet.opacity(0.8) }
        if button.isCancel  { return Color.primary.opacity(0.14) }
        return Color.primary.opacity(0.08)
    }
}

// MARK: - App Switcher Menu (Cmd+Tab style)

/// Small chevron button next to the active-app pill. Tap opens a native
/// `Menu` listing every other running app on the Mac in Cmd+Tab order;
/// selecting one sends a `launchApp` which the Mac handles as an activate.
private struct AppSwitcherMenu: View {
    let apps: [InstalledAppInfo]
    let colorScheme: ColorScheme
    let onSelect: (InstalledAppInfo) -> Void

    var body: some View {
        Menu {
            ForEach(apps) { app in
                Button {
                    onSelect(app)
                } label: {
                    if let data = app.iconData, let ui = UIImage(data: data) {
                        Label {
                            Text(app.displayName)
                        } icon: {
                            Image(uiImage: ui)
                        }
                    } else {
                        Label(app.displayName, systemImage: "app")
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 20, height: 44)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
    }
}

// MARK: - Icon Button (minimal — used for global macros & media)

private struct IconButton: View {
    let symbol: String
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.primary.opacity(0.75))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
                .scaleEffect(isPressed ? 0.88 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}

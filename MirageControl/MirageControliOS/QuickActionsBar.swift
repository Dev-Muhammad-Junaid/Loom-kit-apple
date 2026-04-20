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

struct QuickActionsBar: View {
    let sender: TrackpadSender
    let colorScheme: ColorScheme
    let installedApps: [InstalledAppInfo]
    let activeBundleID: String?
    /// Running apps on the Mac in Cmd+Tab order (most-recently-activated
    /// first). Drives the app-switcher menu next to the app pill.
    let runningBundleIDs: [String]
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
        return Array(store.bindings(for: bundleID).prefix(maxContextualChips))
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
        .frame(height: 64)
        .background(barBackground)
        .clipShape(RoundedRectangle(cornerRadius: MirageTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MirageTheme.Radius.md, style: .continuous)
                .strokeBorder(MirageTheme.tabContainerBorder(colorScheme), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: activeBundleID)
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

    @ViewBuilder
    private var contextualSegment: some View {
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
        .id("ctx-\(activeBundleID ?? "none")")
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        ))
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

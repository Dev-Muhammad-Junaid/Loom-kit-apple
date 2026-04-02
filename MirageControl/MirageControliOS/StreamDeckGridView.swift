//
//  StreamDeckGridView.swift
//  MirageControliOS
//

import SwiftUI
import UIKit

// MARK: - Grid View

struct StreamDeckGridView: View {
    let sender: TrackpadSender
    let colorScheme: ColorScheme
    let installedApps: [InstalledAppInfo]

    // Persisted user preferences
    @AppStorage("pinnedBundleIDs") private var pinnedData: Data = Data()
    @AppStorage("hiddenBundleIDs") private var hiddenData: Data = Data()

    @State private var pinnedIDs: Set<String> = []
    @State private var hiddenIDs: Set<String> = []
    @State private var searchText: String = ""

    // Static shortcuts & media
    private let shortcuts: [MacroItem] = [
         .shortcut(.init(id: "missioncontrol_trigger", displayName: "Mission Control", sfSymbol: "square.grid.2x2",   keys: [])),
        .shortcut(.init(id: "launchpad_trigger",      displayName: "Launchpad",       sfSymbol: "circle.grid.3x3",   keys: [])),
        .shortcut(.init(id: "showdesktop",    displayName: "Show Desktop",    sfSymbol: "desktopcomputer",   keys: ["fn", "f11"])),
        .media(.init(id: "prev",      displayName: "Previous",   sfSymbol: "backward.end.fill",  action: "prev")),
        .media(.init(id: "playpause", displayName: "Play/Pause", sfSymbol: "playpause.fill",     action: "playpause")),
        .media(.init(id: "next",      displayName: "Next",       sfSymbol: "forward.end.fill",   action: "next")),
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    private var filteredApps: [InstalledAppInfo] {
        let visible = installedApps.filter { !hiddenIDs.contains($0.bundleID) }
        if searchText.isEmpty { return visible }
        return visible.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var pinnedApps: [InstalledAppInfo] {
        installedApps.filter { pinnedIDs.contains($0.bundleID) && !hiddenIDs.contains($0.bundleID) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // ── Search bar ──────────────────────────────────
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .font(.system(size: 14))
                    TextField("Search apps…", text: $searchText)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(Color.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colorScheme == .dark ? .white.opacity(0.06) : Color(UIColor.systemFill))
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // ── Quick Actions (shortcuts + media) ───────────
                if searchText.isEmpty {
                    SectionHeader(title: "QUICK ACTIONS")
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(shortcuts) { item in
                            QuickActionButton(item: item, colorScheme: colorScheme) {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                Task {
                                    switch item {
                                    case .media(let m):
                                        await sender.sendMediaAction(m.action)
                                    case .shortcut(let s) where s.keys.isEmpty:
                                        // Macro trigger (Mission Control, Launchpad, etc.)
                                        await sender.sendMacro(item.id)
                                    default:
                                        await sender.sendMacro(item.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }

                // ── Pinned Apps ─────────────────────────────────
                if !pinnedApps.isEmpty && searchText.isEmpty {
                    SectionHeader(title: "PINNED APPS")
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(pinnedApps) { app in
                            AppButton(app: app, isPinned: true, colorScheme: colorScheme,
                                      onTap: { launchApp(app) },
                                      onPin: { togglePin(app) },
                                      onHide: { hideApp(app) })
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }

                // ── All Apps ────────────────────────────────────
                if !filteredApps.isEmpty {
                    SectionHeader(title: searchText.isEmpty ? "ALL APPS" : "RESULTS")
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredApps) { app in
                            AppButton(app: app, isPinned: pinnedIDs.contains(app.bundleID),
                                      colorScheme: colorScheme,
                                      onTap: { launchApp(app) },
                                      onPin: { togglePin(app) },
                                      onHide: { hideApp(app) })
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                } else if installedApps.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading apps from Mac…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            }
        }
        .background(Color.clear)
        .onAppear { loadPreferences() }
    }

    // MARK: - Actions

    private func launchApp(_ app: InstalledAppInfo) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await sender.sendLaunchApp(app.bundleID) }
    }

    private func togglePin(_ app: InstalledAppInfo) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            if pinnedIDs.contains(app.bundleID) {
                pinnedIDs.remove(app.bundleID)
            } else {
                pinnedIDs.insert(app.bundleID)
            }
            savePreferences()
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func hideApp(_ app: InstalledAppInfo) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            hiddenIDs.insert(app.bundleID)
            pinnedIDs.remove(app.bundleID)
            savePreferences()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Persistence

    private func loadPreferences() {
        if let decoded = try? JSONDecoder().decode(Set<String>.self, from: pinnedData) {
            pinnedIDs = decoded
        }
        if let decoded = try? JSONDecoder().decode(Set<String>.self, from: hiddenData) {
            hiddenIDs = decoded
        }
    }

    private func savePreferences() {
        pinnedData = (try? JSONEncoder().encode(pinnedIDs)) ?? Data()
        hiddenData = (try? JSONEncoder().encode(hiddenIDs)) ?? Data()
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.secondary.opacity(0.7))
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 10)
    }
}

// MARK: - App Button (with real icon from Data)

private struct AppButton: View {
    let app: InstalledAppInfo
    let isPinned: Bool
    let colorScheme: ColorScheme
    let onTap: () -> Void
    let onPin: () -> Void
    let onHide: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                appIcon
                    .frame(width: 52, height: 52)

                Text(app.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .scaleEffect(isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
        .contextMenu {
            Button {
                onPin()
            } label: {
                Label(isPinned ? "Unpin from Deck" : "Pin to Deck",
                      systemImage: isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                onHide()
            } label: {
                Label("Hide App", systemImage: "eye.slash")
            }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let data = app.iconData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        } else {
            // Fallback SF Symbol
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "app")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Color.primary.opacity(0.4))
                )
        }
    }
}

// MARK: - Quick Action Button (shortcuts + media)

private struct QuickActionButton: View {
    let item: MacroItem
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: item.sfSymbol)
                    .font(.system(size: 28, weight: .thin))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
                    .frame(width: 48, height: 48)

                Text(item.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
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

    private var iconColor: Color {
        switch item {
        case .shortcut: Color(hex: "A78BFA")
        case .media:    Color.primary.opacity(0.8)
        case .app:      Color(hex: "6C63FF")
        }
    }
}

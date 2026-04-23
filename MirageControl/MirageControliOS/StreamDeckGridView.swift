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
    /// Bundle ID of whichever app is currently frontmost on the Mac.
    /// Rendered as a colored selection ring on the matching tile; tapping
    /// that tile opens the shortcuts sheet directly (no relaunch).
    let activeBundleID: String?
    /// Running apps in Cmd+Tab order (most-recently-activated first), pushed
    /// by the Mac. Powers the app-switcher chevron inside the Quick Actions bar.
    let runningBundleIDs: [String]
    /// Latest AX-derived UI context (dialog buttons, etc.) from the Mac.
    /// When a dialog is active, the Quick Actions bar swaps its contextual
    /// segment to surface the dialog's buttons instead of app shortcuts.
    let uiContext: UIContextSnapshot

    // Persisted user preferences
    @AppStorage("pinnedBundleIDs") private var pinnedData: Data = Data()
    @AppStorage("hiddenBundleIDs") private var hiddenData: Data = Data()

    @State private var pinnedIDs: Set<String> = []
    @State private var hiddenIDs: Set<String> = []
    @State private var searchText: String = ""
    @State private var sheetApp: InstalledAppInfo?
    /// User-toggled override that forces the edit-chip row on even when
    /// AX didn't detect a text field. Controlled by the floating keyboard
    /// FAB in the bottom-right corner; auto-resets whenever AX takes over
    /// (dialog or real text-field focus) or the frontmost app changes.
    @State private var manualEditMode: Bool = false

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
                    RoundedRectangle(cornerRadius: MirageTheme.Radius.sm, style: .continuous)
                        .fill(MirageTheme.searchFieldFill(colorScheme))
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // ── Contextual Quick Actions bar ────────────────
                // Replaces the old static 4-column grid. Morphs as the Mac's
                // frontmost app changes, surfacing that app's top shortcuts
                // inline alongside global macros and media transport.
                if searchText.isEmpty {
                    SectionHeader(title: "QUICK ACTIONS")
                    QuickActionsBar(
                        sender: sender,
                        colorScheme: colorScheme,
                        installedApps: installedApps,
                        activeBundleID: activeBundleID,
                        runningBundleIDs: runningBundleIDs,
                        uiContext: uiContext,
                        manualEditMode: manualEditMode,
                        onOpenAppSheet: { sheetApp = $0 }
                    )
                    .padding(.bottom, 20)
                }

                // ── Pinned Apps ─────────────────────────────────
                if !pinnedApps.isEmpty && searchText.isEmpty {
                    SectionHeader(title: "PINNED APPS")
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(pinnedApps) { app in
                            AppButton(app: app,
                                      isPinned: true,
                                      isActive: app.bundleID == activeBundleID,
                                      colorScheme: colorScheme,
                                      onTap: { handleTap(app) },
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
                            AppButton(app: app,
                                      isPinned: pinnedIDs.contains(app.bundleID),
                                      isActive: app.bundleID == activeBundleID,
                                      colorScheme: colorScheme,
                                      onTap: { handleTap(app) },
                                      onPin: { togglePin(app) },
                                      onHide: { hideApp(app) })
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                } else if installedApps.isEmpty {
                    MirageLoadingStateView(title: "Loading apps from Mac…")
                }
            }
        }
        .background(Color.clear)
        .overlay(alignment: .bottomTrailing) {
            // Only surface the keyboard FAB when neither a dialog nor an
            // AX-detected text field is active — it exists to fill the gap
            // for apps AX can't read (Chrome web content, Electron, etc.).
            if shouldShowKeyboardFAB {
                KeyboardFAB(isActive: manualEditMode) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        manualEditMode.toggle()
                    }
                }
                .padding(.trailing, 24)
                .padding(.bottom, 24)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.7).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .onAppear { loadPreferences() }
        .onChange(of: activeBundleID) { _, _ in
            // Different app in front — the old manual override doesn't
            // apply. Reset so the user decides deliberately.
            if manualEditMode {
                withAnimation(.easeInOut(duration: 0.2)) { manualEditMode = false }
            }
        }
        .onChange(of: uiContext) { _, newContext in
            // AX is now providing context on its own — stand down the
            // manual override so the FAB stops shouting.
            if newContext != .none && manualEditMode {
                withAnimation(.easeInOut(duration: 0.2)) { manualEditMode = false }
            }
        }
        .sheet(item: $sheetApp) { app in
            AppShortcutsSheet(app: app, sender: sender) {
                sheetApp = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Hidden during a dialog (takeover bar owns the screen) and whenever
    /// AX has already surfaced a text/numeric/secure field (the chips are
    /// automatically visible; no toggle needed).
    private var shouldShowKeyboardFAB: Bool {
        uiContext == .none
    }

    // MARK: - Actions

    /// Tap behaviour:
    /// - If this app is already frontmost on the Mac, open the shortcuts
    ///   sheet immediately — don't re-launch.
    /// - Otherwise send a `launchApp` so the Mac brings it to the front,
    ///   then open the shortcuts sheet so the user can trigger one.
    private func handleTap(_ app: InstalledAppInfo) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if app.bundleID != activeBundleID {
            Task { await sender.sendLaunchApp(app.bundleID) }
        }
        sheetApp = app
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
    let isActive: Bool
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
                    .overlay(activeRing)

                Text(app.displayName)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .scaleEffect(isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
            .animation(.easeInOut(duration: 0.2), value: isActive)
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
    private var activeRing: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MirageTheme.violet, lineWidth: 2.5)
                .shadow(color: MirageTheme.violet.opacity(0.55), radius: 6)
                .padding(-3)
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
            RoundedRectangle(cornerRadius: MirageTheme.Radius.sm, style: .continuous)
                .fill(MirageTheme.subtleWellFill(colorScheme))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "app")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Color.primary.opacity(0.4))
                )
        }
    }
}


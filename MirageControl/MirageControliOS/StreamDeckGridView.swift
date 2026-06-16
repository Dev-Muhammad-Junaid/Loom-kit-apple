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
    /// Which auxiliary row (text edit chips vs digit row) is visible in the
    /// Quick Actions bar. Seeded from AX and switched by the two floating
    /// FABs; only one mode is active at a time.
    @State private var editFABMode: EditFABMode = .hidden

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
                SearchField(text: $searchText, prompt: "Search apps")
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
                        editFABMode: editFABMode,
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
            if !isDialogActive {
                VStack(spacing: 12) {
                    NumericFAB(isActive: editFABMode == .numericKeypad) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            switch editFABMode {
                            case .numericKeypad: editFABMode = .hidden
                            case .textEditing: editFABMode = .numericKeypad
                            case .hidden: editFABMode = .numericKeypad
                            }
                        }
                    }
                    KeyboardFAB(isActive: editFABMode == .textEditing) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            switch editFABMode {
                            case .textEditing: editFABMode = .hidden
                            case .numericKeypad: editFABMode = .textEditing
                            case .hidden: editFABMode = .textEditing
                            }
                        }
                    }
                }
                .padding(.trailing, 24)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            loadPreferences()
            syncEditFABModeToAX()
        }
        .onChange(of: activeBundleID) { _, _ in
            // New frontmost app — reset to whatever AX currently reports
            // for that app so the FAB state is fresh.
            syncEditFABModeToAX()
        }
        .onChange(of: uiContext) { _, _ in
            // AX context changed within the same app (focus moved into a
            // text field, dialog opened/closed, etc.). Re-seed so the
            // FAB reflects the new reality unless the user has already
            // diverged from it this turn.
            syncEditFABModeToAX()
        }
        .sheet(item: $sheetApp) { app in
            AppShortcutsSheet(app: app, sender: sender) {
                sheetApp = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var isDialogActive: Bool {
        if case .dialog = uiContext { return true }
        return false
    }

    /// Aligns `editFABMode` with AX: numeric fields prefer the numpad row;
    /// plain / secure text fields prefer the keyboard row; dialog or no
    /// field hides both. Called on app change and on every `uiContext` tick.
    private func syncEditFABModeToAX() {
        let axDesired: EditFABMode = {
            switch uiContext {
            case .dialog, .none:
                return .hidden
            case .textField(let ctx):
                switch ctx.kind {
                case .numeric: return .numericKeypad
                case .text, .secure: return .textEditing
                }
            }
        }()
        guard editFABMode != axDesired else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            editFABMode = axDesired
        }
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

// MARK: - Search Field
//
// Native-feeling iOS search bar built inline. We don't use the
// `.searchable()` modifier here because the parent `ControlView` already
// owns the navigation toolbar (peer name + capture/disconnect buttons),
// and `.searchable()` would hoist a second search affordance into that
// toolbar that only makes sense on the Apps tab. An inline composition
// gives us the same look (magnifying glass + plain `TextField` + clear
// button on a soft fill) without fighting for nav-bar space.

private struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.opacity.combined(with: .scale))
            }
        }
        .font(.body)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background)
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // `#if compiler(>=6.2)` (Xcode 26+) is load-bearing, not just the
        // runtime `#available`: `glassEffect` is an iOS 26 SDK symbol, so
        // the older SDK (Xcode 16/Swift 6.1) can't even compile the branch.
        // Building on Xcode 16 falls through to the plain material.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            shape.fill(.regularMaterial)
                .glassEffect(in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
        #else
        shape.fill(.regularMaterial)
        #endif
    }
}


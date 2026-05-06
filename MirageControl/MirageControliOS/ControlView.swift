//
//  ControlView.swift
//  MirageControliOS
//

import LoomKit
import SwiftUI

extension Notification.Name {
    /// Broadcast when the Mac replies to a menu-shortcut import request.
    /// userInfo keys: `bundleID` (String), `added` (Int), `total` (Int).
    static let appMenuShortcutsImported = Notification.Name("MirageControl.appMenuShortcutsImported")
}

struct ControlView: View {
    let connection: LoomConnectionHandle
    let peerName: String
    let onAuthStatusChanged: (String) -> Void
    let onDisconnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: Tab = .trackpad
    @State private var sender: TrackpadSender?

    // Bidirectional state
    @State private var activeAppName: String?
    @State private var activeBundleID: String?
    @State private var installedApps: [InstalledAppInfo] = []
    /// Bundle IDs of apps currently running on the Mac, in Cmd+Tab order
    /// (most-recently-activated first). Pushed by `RunningAppMonitor`.
    @State private var runningBundleIDs: [String] = []
    /// Latest accessibility-derived context snapshot from the Mac. When a
    /// modal dialog is visible on the frontmost app this carries its
    /// buttons; the Quick Actions bar swaps its contextual segment to
    /// surface them.
    @State private var uiContext: UIContextSnapshot = .none
    @State private var screenshotImage: UIImage?
    @State private var isRequestingScreenshot = false   // in-flight guard
    @State private var isScreenshotPresented = false
    @State private var screenshotTimeoutTask: Task<Void, Never>?
    @State private var screenshotErrorMessage: String?
    /// Token of the most recently issued screenshot request. Responses
    /// echo this value back; any mismatch is dropped on the floor so a
    /// slow, late-arriving capture from a previous tap can't show up
    /// inside the next request's full-screen cover.
    @State private var screenshotRequestID: String?

    // ── Capture-menu state ──────────────────────────────────────────
    /// What the *next* `screenshotData` payload is for. Drives whether we
    /// jump to the preview, the region cropper, or the OCR sheet. Set at
    /// request time and cleared on response / error / timeout.
    @State private var screenshotIntent: ScreenshotIntent = .fullScreen
    /// Full-screen reference shipped to `RegionCropView` so the user can
    /// draw a rect against actual Mac pixels rather than a black canvas.
    @State private var regionReferenceImage: UIImage?
    @State private var isRegionCropPresented = false
    /// Image fed into `OCRResultView` once the OCR-intent capture lands.
    @State private var ocrImage: UIImage?
    @State private var isOCRPresented = false
    /// Latest window list pushed back from the Mac and the picker's load
    /// state. We re-fetch every time the picker opens so the user never
    /// sees stale entries for windows that were closed since the last request.
    @State private var availableWindows: [WindowInfo] = []
    @State private var isWindowPickerPresented = false
    @State private var isWindowListLoading = false
    @State private var windowListRequestID: String?

    /// Drives post-arrival routing for `screenshotData`. Each tap path sets
    /// the matching intent so the response flows into the right UI without
    /// a global "what was the last button?" state machine.
    enum ScreenshotIntent: Equatable {
        case fullScreen
        /// First leg of the region flow: we asked for a full-screen capture
        /// that's about to feed into `RegionCropView`.
        case regionPicking
        /// Second leg of the region flow: the actual cropped capture the
        /// user wants to save / share / annotate.
        case regionFinal
        /// Capturing a single window picked from the window list sheet.
        case window(WindowInfo)
        /// Capturing for OCR rather than for visual presentation.
        case ocr
    }

    enum Tab: String, CaseIterable {
        case trackpad   = "Trackpad"
        case streamdeck = "Apps"

        var icon: String {
            switch self {
            case .trackpad:   "hand.draw"
            case .streamdeck: "square.grid.3x2"
            }
        }
    }

    var body: some View {
        ZStack {
            MirageTheme.canvasBackground(colorScheme).ignoresSafeArea()

            if let sender {
                VStack(spacing: 0) {
                    navBar
                    Divider().overlay(MirageTheme.navDivider(colorScheme))
                    tabSwitcher
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider().overlay(MirageTheme.navDivider(colorScheme))

                    Group {
                        switch selectedTab {
                        case .trackpad:
                            TrackpadView(sender: sender, colorScheme: colorScheme)
                        case .streamdeck:
                            StreamDeckGridView(
                                sender: sender,
                                colorScheme: colorScheme,
                                installedApps: installedApps,
                                activeBundleID: activeBundleID,
                                runningBundleIDs: runningBundleIDs,
                                uiContext: uiContext
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: selectedTab)
                }
            } else {
                MirageLoadingStateView(
                    title: "Initializing…",
                    verticalPadding: 48,
                    progressScale: 1.28
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Screenshot sheet
        .fullScreenCover(isPresented: $isScreenshotPresented) {
            ZStack {
                if let img = screenshotImage {
                    ScreenshotPreviewView(image: img) {
                        isScreenshotPresented = false
                    }
                } else {
                    // Loading state while waiting for Mac response
                    ZStack {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 18) {
                            MirageLoadingStateView(
                                title: "Capturing screen…",
                                verticalPadding: 0,
                                progressScale: 1.35,
                                progressTint: .white,
                                titleColor: .white.opacity(0.88)
                            )
                            Button("Cancel") {
                                screenshotTimeoutTask?.cancel()
                                screenshotRequestID = nil
                                isRequestingScreenshot = false
                                isScreenshotPresented = false
                            }
                            .font(MirageTheme.TypeStyle.captionRounded)
                            .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        .alert("Screenshot Failed", isPresented: Binding(
            get: { screenshotErrorMessage != nil },
            set: { if !$0 { screenshotErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { screenshotErrorMessage = nil }
        } message: {
            Text(screenshotErrorMessage ?? "")
        }
        // Region picker — fronts after a regionPicking-intent capture lands.
        .fullScreenCover(isPresented: $isRegionCropPresented) {
            if let reference = regionReferenceImage {
                RegionCropView(image: reference) { rect in
                    handleRegionConfirm(rect)
                }
            } else {
                // Defensive: shouldn't happen because we only set the flag
                // after the reference image is captured.
                Color.black.ignoresSafeArea()
                    .onAppear { isRegionCropPresented = false }
            }
        }
        // Window picker — independent of the capture state machine; the
        // user can refresh / cancel without disturbing an in-flight request.
        .sheet(isPresented: $isWindowPickerPresented) {
            WindowPickerView(
                windows: availableWindows,
                runningBundleIDs: runningBundleIDs,
                isLoading: isWindowListLoading,
                onPick: { window in
                    isWindowPickerPresented = false
                    beginCapture(intent: .window(window),
                                 mode: .window(windowID: window.windowID))
                },
                onRefresh: {
                    if let sender { refreshWindowList(sender: sender) }
                },
                onCancel: { isWindowPickerPresented = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // OCR result sheet — fronts after an ocr-intent capture lands.
        .sheet(isPresented: $isOCRPresented) {
            if let img = ocrImage {
                OCRResultView(image: img) {
                    isOCRPresented = false
                    ocrImage = nil
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .task {
            let s = TrackpadSender(handle: connection)
            sender = s
            // Load cached app list for instant display
            if let cached = Self.loadCachedAppList() {
                installedApps = cached
            }
            // Then request fresh list from Mac
            Task { await s.requestAppList() }
            // Single consolidated message loop — no competing consumers
            await listenForHostMessages()
        }
    }

    #if DEBUG
    private func messageTypeName(_ m: ControlMessage) -> String {
        switch m {
        case .authorizationStatus: "authorizationStatus"
        case .activeAppUpdate: "activeAppUpdate"
        case .screenshotData: "screenshotData"
        case .screenshotError: "screenshotError"
        case .appListResponse: "appListResponse"
        case .appMenuShortcutsResponse: "appMenuShortcutsResponse"
        case .runningAppsUpdate: "runningAppsUpdate"
        case .uiContextUpdate: "uiContextUpdate"
        case .windowListResponse: "windowListResponse"
        default: "other"
        }
    }
    #endif

    // MARK: - Single Message Listener
    //
    // All messages from the Mac come through here. Splitting this loop
    // across multiple views causes AsyncSequence racing where messages get
    // silently consumed by the wrong listener.

    private func listenForHostMessages() async {
        for await data in connection.messages {
            let message: ControlMessage
            do {
                message = try JSONDecoder().decode(ControlMessage.self, from: data)
            } catch {
                #if DEBUG
                print("MirageControliOS: ⚠️ Failed to decode ControlMessage (\(data.count)B): \(error)")
                #endif
                continue
            }
            #if DEBUG
            print("MirageControliOS: 📥 \(data.count)B \(messageTypeName(message))")
            #endif
            await MainActor.run {
                switch message {
                case let .authorizationStatus(status):
                    onAuthStatusChanged(status)

                case let .activeAppUpdate(name, bundleID):
                    withAnimation(.easeInOut(duration: 0.2)) {
                        activeAppName = name
                        activeBundleID = bundleID
                    }

                case let .screenshotData(requestID, data):
                    // Drop responses for a request we've already given up on
                    // (timeout fired, user dismissed, or a newer request
                    // overwrote the token).
                    guard requestID == screenshotRequestID else {
                        #if DEBUG
                        print("MirageControliOS: ⏭️ dropping stale screenshotData (\(requestID))")
                        #endif
                        break
                    }
                    screenshotTimeoutTask?.cancel()
                    isRequestingScreenshot = false
                    screenshotRequestID = nil

                    guard let img = UIImage(data: data) else {
                        // Data arrived but was not a valid image
                        isScreenshotPresented = false
                        isRegionCropPresented = false
                        screenshotErrorMessage = "Received invalid image data from Mac."
                        screenshotIntent = .fullScreen
                        break
                    }

                    // Branch on the intent that requested this capture so the
                    // image lands in the right UI surface — preview sheet,
                    // crop overlay, or OCR sheet.
                    switch screenshotIntent {
                    case .fullScreen, .window, .regionFinal:
                        screenshotImage = img
                        // isScreenshotPresented is already true; ZStack swaps to ScreenshotPreviewView
                        screenshotIntent = .fullScreen
                    case .regionPicking:
                        // Tear down the loading overlay; hand off to crop UI.
                        isScreenshotPresented = false
                        regionReferenceImage = img
                        isRegionCropPresented = true
                    case .ocr:
                        isScreenshotPresented = false
                        ocrImage = img
                        isOCRPresented = true
                        screenshotIntent = .fullScreen
                    }

                case let .screenshotError(requestID, message):
                    guard requestID == screenshotRequestID else {
                        #if DEBUG
                        print("MirageControliOS: ⏭️ dropping stale screenshotError (\(requestID))")
                        #endif
                        break
                    }
                    screenshotTimeoutTask?.cancel()
                    isRequestingScreenshot = false
                    screenshotRequestID = nil
                    isScreenshotPresented = false
                    isRegionCropPresented = false
                    screenshotIntent = .fullScreen
                    screenshotErrorMessage = message

                case let .windowListResponse(requestID, windows):
                    // The window picker may have been dismissed before the
                    // list arrived; we still keep the cached list so the
                    // next open is instant.
                    if windowListRequestID == requestID {
                        windowListRequestID = nil
                        isWindowListLoading = false
                    }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        availableWindows = windows
                    }

                case let .appListResponse(apps):
                    withAnimation(.easeInOut(duration: 0.2)) {
                        installedApps = apps
                    }
                    // Cache to disk for instant display on next connect
                    Self.cacheAppList(apps)

                case let .runningAppsUpdate(ids):
                    withAnimation(.easeInOut(duration: 0.2)) {
                        runningBundleIDs = ids
                    }

                case let .uiContextUpdate(snapshot):
                    #if DEBUG
                    switch snapshot {
                    case .none:
                        print("MirageControliOS: 📥 uiContextUpdate .none")
                    case .dialog(let ctx):
                        print("MirageControliOS: 📥 uiContextUpdate dialog title='\(ctx.title ?? "")' buttons=\(ctx.buttons.map(\.title))")
                    case .textField(let ctx):
                        print("MirageControliOS: 📥 uiContextUpdate textField kind=\(ctx.kind.rawValue)")
                    }
                    #endif
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        uiContext = snapshot
                    }

                case let .appMenuShortcutsResponse(bundleID, shortcuts):
                    let added = ShortcutStore.shared.importBindings(shortcuts, for: bundleID)
                    NotificationCenter.default.post(
                        name: .appMenuShortcutsImported,
                        object: nil,
                        userInfo: [
                            "bundleID": bundleID,
                            "added": added,
                            "total": shortcuts.count
                        ]
                    )

                default:
                    break
                }
            }
        }
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(peerName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(MirageTheme.success)
                        .frame(width: 6, height: 6)
                        .shadow(color: MirageTheme.success.opacity(0.8), radius: 4)

                    if let app = activeAppName {
                        Text(app)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.secondary)
                            .id(app)
                    } else {
                        Text("Connected")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 12) {
                // Capture capsule — primary tap = full-screen, long-press or
                // caret tap = options menu (Region, Window, OCR Text).
                CaptureCapsule(
                    isBusy: isRequestingScreenshot,
                    onFullScreen: { beginCapture(intent: .fullScreen, mode: .fullScreen) },
                    onRegion:     { beginCapture(intent: .regionPicking, mode: .fullScreen) },
                    onWindow:     { openWindowPicker() },
                    onOCR:        { beginCapture(intent: .ocr, mode: .fullScreen) }
                )

                // Disconnect button
                Button(action: onDisconnect) {
                    HStack(spacing: 5) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12))
                        Text("Disconnect")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.07))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Tab Switcher

    private var tabSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { tab in
                TabPill(tab: tab, isSelected: selectedTab == tab, colorScheme: colorScheme) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                        selectedTab = tab
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: MirageTheme.Radius.md, style: .continuous)
                .fill(MirageTheme.tabContainerFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: MirageTheme.Radius.md, style: .continuous)
                        .strokeBorder(MirageTheme.tabContainerBorder(colorScheme), lineWidth: 1)
                )
        )
    }

    // MARK: - Capture flow

    /// Common entry point for every "ask the Mac to capture something" flow.
    /// Sets the routing intent, allocates a fresh request token, opens the
    /// loading overlay, and arms the 8 s timeout. Sheets that branch off
    /// the eventual response (region crop, OCR) are presented in the
    /// `screenshotData` handler based on `screenshotIntent`.
    private func beginCapture(intent: ScreenshotIntent, mode: CaptureMode) {
        guard let sender, !isRequestingScreenshot else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        screenshotImage = nil
        screenshotErrorMessage = nil
        isRequestingScreenshot = true
        // Region-picking and OCR intents don't show the loading overlay
        // until the user has confirmed the capture path; the loading
        // overlay only fronts for "you'll see this image directly" intents.
        switch intent {
        case .fullScreen, .window, .regionFinal:
            isScreenshotPresented = true
        case .regionPicking, .ocr:
            isScreenshotPresented = true   // keep a uniform loader
        }
        screenshotIntent = intent
        let requestID = UUID().uuidString
        screenshotRequestID = requestID

        Task { await sender.requestScreenshot(requestID: requestID, mode: mode) }

        screenshotTimeoutTask?.cancel()
        screenshotTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }
            guard screenshotRequestID == requestID else { return }
            screenshotRequestID = nil
            isRequestingScreenshot = false
            isScreenshotPresented = false
            isRegionCropPresented = false
            screenshotIntent = .fullScreen
            screenshotErrorMessage = "The Mac didn't respond in time. Make sure Screen Recording is allowed in System Settings > Privacy & Security > Screen Recording."
        }
    }

    /// Triggered from the capture menu's "Window…" item. Opens the picker
    /// sheet with whatever cached list we have, then refreshes from the Mac
    /// in parallel so the rows update under the user's finger.
    private func openWindowPicker() {
        guard let sender else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isWindowPickerPresented = true
        refreshWindowList(sender: sender)
    }

    private func refreshWindowList(sender: TrackpadSender) {
        let requestID = UUID().uuidString
        windowListRequestID = requestID
        isWindowListLoading = true
        Task { await sender.requestWindowList(requestID: requestID) }

        // 6 s safety net so the spinner doesn't hang forever if the Mac
        // never replies (TCC pulled, app crashed, etc.).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if windowListRequestID == requestID {
                windowListRequestID = nil
                isWindowListLoading = false
            }
        }
    }

    // MARK: - Region crop confirmation

    /// Called by `RegionCropView` once the user picks a rect. We tear down
    /// the crop sheet and immediately ask the Mac for a *fresh* capture
    /// of just that rect — much sharper than re-cropping the iPad-side
    /// JPEG, since the Mac still has the native pixel grid.
    private func handleRegionConfirm(_ normalizedRect: CGRect?) {
        isRegionCropPresented = false
        regionReferenceImage = nil
        guard let rect = normalizedRect else {
            // User cancelled — go back to idle state.
            screenshotIntent = .fullScreen
            return
        }
        let mode = CaptureMode.region(
            x: Float(rect.origin.x),
            y: Float(rect.origin.y),
            width: Float(rect.width),
            height: Float(rect.height)
        )
        beginCapture(intent: .regionFinal, mode: mode)
    }
}

// MARK: - TabPill

private struct TabPill: View {
    let tab: ControlView.Tab
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    private var activeShadow: Color {
        colorScheme == .dark ? .clear : .black.opacity(0.06)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: MirageTheme.Radius.md - 3, style: .continuous)
                    .fill(isSelected ? MirageTheme.tabPillSelectedFill(colorScheme) : Color.clear)
                    .shadow(color: activeShadow, radius: 4, y: 1)
                    .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isSelected)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Capture Capsule
//
// Capsule with two zones: a primary camera button on the left and a caret
// menu on the right. Both expose the same options menu (Region, Window,
// OCR Text), but the camera button additionally fires the default
// full-screen capture on tap so the most common path stays a single tap.
//
// Long-pressing the camera *also* opens the menu — that's the SwiftUI
// `Menu(primaryAction:)` contract — so power users have three identical
// ways to reach the menu (long-press, tap caret, swipe down).

private struct CaptureCapsule: View {
    let isBusy: Bool
    let onFullScreen: () -> Void
    let onRegion: () -> Void
    let onWindow: () -> Void
    let onOCR: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            primaryButton
            divider
            caretMenu
        }
        .background(
            Capsule()
                .fill(Color.primary.opacity(isBusy ? 0.04 : 0.07))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        )
        .clipShape(Capsule())
        .opacity(isBusy ? 0.85 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isBusy)
    }

    private var primaryButton: some View {
        // SwiftUI Menu with `primaryAction:` — tap fires the action, long
        // press opens the menu. Disabled-on-busy is enforced by the parent.
        Menu {
            menuItems
        } label: {
            ZStack {
                Color.clear.frame(width: 44, height: 36)
                if isBusy {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(Color.primary.opacity(0.5))
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
            }
            .contentShape(Rectangle())
        } primaryAction: {
            guard !isBusy else { return }
            onFullScreen()
        }
        .disabled(isBusy)
        .accessibilityLabel("Capture")
        .accessibilityHint("Tap for a full-screen capture, long-press for region or window options.")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 22)
    }

    private var caretMenu: some View {
        Menu {
            menuItems
        } label: {
            ZStack {
                Color.clear.frame(width: 28, height: 36)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(isBusy ? 0.35 : 0.7))
            }
            .contentShape(Rectangle())
        }
        .disabled(isBusy)
        .accessibilityLabel("Capture options")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            onFullScreen()
        } label: {
            Label("Full Screen", systemImage: "rectangle.dashed")
        }
        Button {
            onRegion()
        } label: {
            Label("Region…", systemImage: "rectangle.dashed.badge.record")
        }
        Button {
            onWindow()
        } label: {
            Label("Window…", systemImage: "macwindow")
        }
        Divider()
        Button {
            onOCR()
        } label: {
            Label("Recognize Text", systemImage: "text.viewfinder")
        }
    }
}

// MARK: - App List Caching

extension ControlView {
    private static var appListCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("mirage_installed_apps.json")
    }

    static func cacheAppList(_ apps: [InstalledAppInfo]) {
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(apps) {
                try? await data.write(to: appListCacheURL, options: .atomic)
            }
        }
    }

    static func loadCachedAppList() -> [InstalledAppInfo]? {
        guard let data = try? Data(contentsOf: appListCacheURL),
              let apps = try? JSONDecoder().decode([InstalledAppInfo].self, from: data) else {
            return nil
        }
        return apps
    }
}

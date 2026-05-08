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
        NavigationStack {
            ZStack {
                MirageTheme.canvasBackground(colorScheme).ignoresSafeArea()

                if let sender {
                    VStack(spacing: 0) {
                        tabSwitcher
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(peerName)
                            .font(.headline)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(MirageTheme.success)
                                .frame(width: 6, height: 6)
                            Text(activeAppName ?? "Connected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CaptureCapsule(
                        isBusy: isRequestingScreenshot,
                        onFullScreen: { beginCapture(intent: .fullScreen, mode: .fullScreen) },
                        onRegion:     { beginCapture(intent: .regionPicking, mode: .fullScreen) },
                        onWindow:     { openWindowPicker() },
                        onOCR:        { beginCapture(intent: .ocr, mode: .fullScreen) }
                    )
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onDisconnect) {
                        Image(systemName: "minus.circle")
                    }
                    .tint(.red)
                    .accessibilityLabel("Disconnect")
                }
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

    // MARK: - Tab Switcher

    private var tabSwitcher: some View {
        Picker("View", selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .labelStyle(.titleAndIcon)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
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

// MARK: - Capture Capsule

private struct CaptureCapsule: View {
    let isBusy: Bool
    let onFullScreen: () -> Void
    let onRegion: () -> Void
    let onWindow: () -> Void
    let onOCR: () -> Void

    var body: some View {
        Menu {
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
        } label: {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "camera.viewfinder")
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
        } primaryAction: {
            guard !isBusy else { return }
            onFullScreen()
        }
        .disabled(isBusy)
        .accessibilityLabel("Capture")
        .accessibilityHint("Tap for a full-screen capture, long-press for region or window options.")
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

//
//  ControlView.swift
//  DeckHandiOS
//

import LoomKit
import SwiftUI

extension Notification.Name {
    /// Broadcast when the Mac replies to a menu-shortcut import request.
    /// userInfo keys: `bundleID` (String), `added` (Int), `total` (Int).
    static let appMenuShortcutsImported = Notification.Name("DeckHand.appMenuShortcutsImported")
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

    // ── Live mini mirror (WID-403) ──────────────────────────────────
    /// Whether the user has the floating mirror thumbnail enabled. Drives
    /// startMirror/stopMirror on the wire and the overlay's visibility.
    @State private var isMirrorActive = false
    /// Latest decoded mirror frame. Replaced wholesale per frame — at
    /// ~480px these are ~1 MB decoded, and only one is ever retained.
    @State private var mirrorImage: UIImage?
    /// Highest sequence number rendered; lower/equal arrivals are stale
    /// (shouldn't happen on an ordered transport, but cheap to guard).
    @State private var mirrorLastSeq: UInt64 = 0

    /// `true` once any `authorizationStatus` has arrived from the host.
    /// Gates the resync poll below — we stop asking once we've heard
    /// anything, because from then on pushes are flowing.
    @State private var hasReceivedAuthStatus = false
    /// Last status received — keeps a "denied" verdict from being stomped
    /// by a liveness timeout.
    @State private var lastAuthStatus = "pending"

    // ── Liveness heartbeat ──────────────────────────────────────────
    /// Time the last pong arrived. The heartbeat loop sends a ping every
    /// 2 s; if no pong lands within the timeout the host is provably gone
    /// (quit, crashed, network dropped) and we bounce to the picker —
    /// regardless of what the transport's cached state claims.
    @State private var lastPongAt: Date?
    /// Set once any pong arrives; before that the timeout isn't enforced
    /// (covers connecting to an older host build that doesn't speak ping).
    @State private var heartbeatEstablished = false

    // ── Host capabilities ───────────────────────────────────────────
    /// What the Mac can actually execute right now, as reported by the
    /// host on session start and refreshed periodically. `nil` = not yet
    /// reported. Drives the warning banner so "nothing happens" always
    /// has a visible reason.
    @State private var hostAccessibilityGranted: Bool?
    @State private var hostScreenRecordingGranted: Bool?

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
                DeckHandTheme.canvasBackground(colorScheme).ignoresSafeArea()

                if let sender {
                    VStack(spacing: 0) {
                        // Host-permission warnings: the host reports what it
                        // can execute; missing permissions show here instead
                        // of taps failing silently.
                        if hostAccessibilityGranted == false {
                            HostCapabilityBanner(
                                text: "The Mac is missing Accessibility permission — mouse, keyboard, and shortcuts won't work. Fix it in the Mac's menu bar panel."
                            )
                        }
                        if hostScreenRecordingGranted == false {
                            HostCapabilityBanner(
                                text: "The Mac is missing Screen Recording permission — screenshots and the live mirror won't work."
                            )
                        }

                        tabSwitcher
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        Divider().overlay(DeckHandTheme.navDivider(colorScheme))

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
                    DeckHandLoadingStateView(
                        title: "Initializing…",
                        verticalPadding: 48,
                        progressScale: 1.28
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Floating live-mirror thumbnail (WID-403). Sits above both
            // tabs so the user can keep an eye on the Mac while driving
            // the trackpad or the shortcut deck.
            .overlay(alignment: .bottomTrailing) {
                if isMirrorActive {
                    MirrorThumbnailView(
                        image: mirrorImage,
                        onClose: { toggleMirror() },
                        onExpansionChanged: { expanded in
                            renegotiateMirror(expanded: expanded)
                        }
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 96)   // clear the gesture button bar
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.snappy(duration: 0.2), value: isMirrorActive)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        // Long Mac names ("Junaid's MacBook Pro (16-inch,
                        // 2023)") overflow the principal toolbar slot —
                        // middle truncation keeps both the owner and model.
                        Text(peerName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(DeckHandTheme.success)
                                .frame(width: 6, height: 6)
                            Text(activeAppName ?? "Connected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        // Surface the live connection id so the session can be
                        // matched against the Mac and a silent session swap is
                        // visible in the UI.
                        Text("session \(connection.id.uuidString.prefix(8))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Live mini mirror toggle (WID-403).
                    Button {
                        toggleMirror()
                    } label: {
                        Image(systemName: isMirrorActive
                              ? "rectangle.fill.on.rectangle.fill"
                              : "rectangle.on.rectangle")
                    }
                    .tint(isMirrorActive ? DeckHandTheme.violet : nil)
                    .accessibilityLabel(isMirrorActive ? "Stop live mirror" : "Start live mirror")
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
                // `ToolbarSpacer` is iOS 26 SDK-only — compile-time gate it
                // (Xcode 26 / Swift 6.2) so the toolbar still builds on
                // Xcode 16; the spacer is purely cosmetic on older OSes.
                #if compiler(>=6.2)
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                #endif
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
                            DeckHandLoadingStateView(
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
                            .font(DeckHandTheme.TypeStyle.captionRounded)
                            .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
            // Release the captured image once the preview is fully gone.
            // A native-resolution capture of a 5K display decodes to
            // ~50 MB; holding it in @State after dismissal kept that
            // memory resident until the *next* capture overwrote it.
            .onDisappear { screenshotImage = nil }
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

            // ── Authorization resync poll ───────────────────────────
            // The host pushes `authorizationStatus`, and the handle's
            // message stream buffers, so the normal path never loses it.
            // But the push itself is a network send that can fail — and a
            // lost `granted` would strand this view on the approval
            // overlay while the Mac thinks the session is live. Poll
            // until a DECISIVE status (granted/denied) arrives — NOT the
            // initial "pending" the host emits before the user decides.
            // Queries sent while we're still pending sit buffered host-side
            // (the host only consumes this connection's inbox after it
            // authorizes) and are all answered "granted" the moment approval
            // lands, healing any dropped push. Bounded at 20 attempts
            // (~60 s, past the host's 45 s pending expiry) so the loop
            // always terminates even if the view outlives a dead connection.
            Task {
                for _ in 0..<20 {
                    guard !hasReceivedAuthStatus else { break }
                    await s.requestAuthorizationStatus()
                    try? await Task.sleep(for: .seconds(3))
                }
            }

            // ── Liveness heartbeat ──────────────────────────────────
            // Ping every 2 s; declare the host dead after ~6 s of pong
            // silence (three missed beats). Structured child of .task,
            // so view teardown cancels it cleanly — no phantom
            // disconnects from replaced views.
            let heartbeat = Task {
                var seq: UInt64 = 0
                while !Task.isCancelled {
                    seq &+= 1
                    await s.sendPing(seq: seq)
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    let silent = await MainActor.run { () -> Bool in
                        guard heartbeatEstablished, let lastPongAt else { return false }
                        return Date().timeIntervalSince(lastPongAt) > 6
                    }
                    if silent {
                        await MainActor.run {
                            if lastAuthStatus != "denied" {
                                onAuthStatusChanged("host_disconnected")
                            }
                        }
                        return
                    }
                }
            }
            defer { heartbeat.cancel() }

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
                message = try ControlMessageCoding.decoder.decode(ControlMessage.self, from: data)
            } catch {
                #if DEBUG
                print("DeckHandiOS: ⚠️ Failed to decode ControlMessage (\(data.count)B): \(error)")
                #endif
                continue
            }
            #if DEBUG
            print("DeckHandiOS: 📥 \(data.count)B \(messageTypeName(message))")
            #endif
            // Mirror frames are the only high-rate inbound payload (≤20/s)
            // and JPEG decode is the heavy part — handle them here on the
            // listener task so decode stays off the main thread, and only
            // hop to MainActor for the cheap state swap.
            if case let .mirrorFrame(seq, frameData) = message {
                guard let decoded = UIImage(data: frameData)?.preparingForDisplay() else { continue }
                await MainActor.run {
                    guard isMirrorActive else { return }
                    // Ordered transport: a sequence REGRESSION can only mean
                    // the host restarted the stream (quality re-negotiation),
                    // so adopt the new numbering. Only exact duplicates drop.
                    guard seq != mirrorLastSeq else { return }
                    mirrorLastSeq = seq
                    mirrorImage = decoded
                }
                continue
            }
            await MainActor.run {
                switch message {
                case .pong:
                    lastPongAt = Date()
                    heartbeatEstablished = true

                case let .hostCapabilities(accessibility, screenRecording):
                    withAnimation(.easeInOut(duration: 0.2)) {
                        hostAccessibilityGranted = accessibility
                        hostScreenRecordingGranted = screenRecording
                    }

                case let .authorizationStatus(status):
                    // Always-on so the pending→granted/denied transition is
                    // visible in Console.app for release/TestFlight, not just
                    // Xcode-attached DEBUG. `decisive` mirrors the resync-poll
                    // gate below.
                    DeckHandLog.connection.info("🔑 iPad authorizationStatus = \(status, privacy: .public) (decisive=\(status != "pending"))")
                    // Only a DECISIVE verdict disarms the resync poll. The
                    // host pushes "pending" the instant the connection lands
                    // (before the user has decided); treating that as "heard
                    // back" used to stop the poll immediately, so if the later
                    // "granted" push was dropped on the wire the iPad sat on
                    // the approval overlay forever. The poll is precisely the
                    // recovery path for a lost push — keep it alive until the
                    // host actually grants or denies.
                    if status != "pending" {
                        hasReceivedAuthStatus = true
                    }
                    lastAuthStatus = status
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
                        print("DeckHandiOS: ⏭️ dropping stale screenshotData (\(requestID))")
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
                    // The mirror stream reuses this channel with a fixed
                    // token: stop the mirror and surface the reason rather
                    // than letting the stale-request guard eat it.
                    if requestID == "mirror" {
                        if isMirrorActive {
                            isMirrorActive = false
                            mirrorImage = nil
                            screenshotErrorMessage = message
                        }
                        break
                    }
                    guard requestID == screenshotRequestID else {
                        #if DEBUG
                        print("DeckHandiOS: ⏭️ dropping stale screenshotError (\(requestID))")
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
                        print("DeckHandiOS: 📥 uiContextUpdate .none")
                    case .dialog(let ctx):
                        print("DeckHandiOS: 📥 uiContextUpdate dialog title='\(ctx.title ?? "")' buttons=\(ctx.buttons.map(\.title))")
                    case .textField(let ctx):
                        print("DeckHandiOS: 📥 uiContextUpdate textField kind=\(ctx.kind.rawValue)")
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

        // No stream-end inference here. Liveness is decided by exactly one
        // mechanism — the ping/pong heartbeat above — which can't misfire
        // on view replacement (it's a structured child of this view's
        // .task) and detects every real death within seconds, including
        // abrupt host kills the transport never notices. ContentRootView's
        // events loop still handles explicit `.disconnected` events.
    }

    // MARK: - Live mirror control (WID-403)


    /// Flips the mirror on/off: updates local UI state immediately for
    /// responsiveness, then tells the Mac. Frame state is reset on stop so
    /// a later restart begins with the loading placeholder, and the last
    /// (~1 MB decoded) frame isn't retained while the mirror is hidden.
    private func toggleMirror() {
        guard let sender else { return }
        isMirrorActive.toggle()
        if isMirrorActive {
            mirrorLastSeq = 0
            mirrorImage = nil
            Task { await sender.startMirror() }
        } else {
            mirrorImage = nil
            Task { await sender.stopMirror() }
        }
    }

    /// Re-negotiates the mirror stream resolution to match the thumbnail
    /// size: 640px compact, 1024px expanded (sharp text at the 340 pt
    /// Retina width). Stop+start is cheap — a sub-second hiccup — and the
    /// sequence counter resets with the new stream so fresh frames aren't
    /// dropped as stale.
    private func renegotiateMirror(expanded: Bool) {
        guard let sender, isMirrorActive else { return }
        mirrorLastSeq = 0
        Task {
            await sender.stopMirror()
            await sender.startMirror(maxWidth: expanded ? 1024 : 640)
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

// MARK: - Host capability banner

/// Compact warning strip shown when the host reports a missing macOS
/// permission. The remote can't fix it, but it CAN say why nothing works.
private struct HostCapabilityBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .transition(.opacity)
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
        return caches.appendingPathComponent("deckhand_installed_apps.json")
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

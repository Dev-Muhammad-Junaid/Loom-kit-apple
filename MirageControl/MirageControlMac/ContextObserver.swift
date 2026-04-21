//
//  ContextObserver.swift
//  MirageControlMac
//
//  Watches the frontmost app's Accessibility tree for modal dialogs /
//  sheets / alerts and broadcasts `UIContextSnapshot`s to every connected
//  iPad. Phase 1 scope:
//
//    • Detects an attached sheet (`AXSheet` child of the focused window)
//      or a free-standing modal window (window subrole `AXDialog` /
//      `AXSystemDialog`).
//    • Enumerates `AXButton` descendants (bounded depth / count).
//    • Tags the system-declared default + cancel buttons so the iPad can
//      render them with the correct emphasis.
//    • Stores a per-snapshot `[id: AXUIElement]` lookup so the iPad can
//      trigger a button by echoing its synthetic UUID back through
//      `triggerContextAction`.
//
//  We reuse the Accessibility permission the app already holds for input
//  injection and menu-shortcut discovery — no new entitlement required.
//
//  Intentional non-goals in Phase 1: focused text-field context, color /
//  save / open panel specifics, per-app bespoke integrations.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import LoomKit

@MainActor
final class ContextObserver {
    static let shared = ContextObserver()

    // MARK: - State

    private var connections: [UUID: LoomConnectionHandle] = [:]

    /// Latest snapshot broadcast. New connections receive this on attach.
    private var latestSnapshot: UIContextSnapshot = .none
    /// AX handles keyed by the synthetic UUID we ship to the iPad.
    /// Cleared and repopulated on every snapshot.
    private var buttonElementsByID: [String: AXUIElement] = [:]

    private var cancellables = Set<AnyCancellable>()

    // Currently observed app
    private var currentPID: pid_t?
    private var currentAppElement: AXUIElement?
    private var currentObserver: AXObserver?

    /// Coalesces bursts of AX notifications — Chrome-style apps can fire
    /// a dozen within a few milliseconds while a sheet animates in.
    private var debounceTask: Task<Void, Never>?
    private static let debounceNanoseconds: UInt64 = 75_000_000

    // AX notifications we want to know about on the frontmost app.
    private static let appNotifications: [String] = [
        kAXFocusedWindowChangedNotification as String,
        kAXMainWindowChangedNotification as String,
        kAXWindowCreatedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
    ]

    // Per-window notifications (sheets + destruction). Registered on each
    // window we observe.
    private static let windowNotifications: [String] = [
        "AXSheetCreated",
        kAXUIElementDestroyedNotification as String,
    ]

    private init() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                Task { @MainActor in
                    self?.attach(to: app)
                }
            }
            .store(in: &cancellables)

        // Seed from the currently frontmost app at startup.
        if let front = NSWorkspace.shared.frontmostApplication {
            attach(to: front)
        }
    }

    // MARK: - Connection wiring

    func addConnection(_ handle: LoomConnectionHandle, id: UUID) {
        connections[id] = handle
        Task { try? await send(latestSnapshot, to: handle) }
    }

    func removeConnection(id: UUID) {
        connections.removeValue(forKey: id)
    }

    /// Called from `ControlReceiver` when the iPad taps a dialog chip.
    /// Stale IDs (from an older snapshot) are silently ignored, which is
    /// the correct behaviour — the user saw a button that's gone now.
    func performAction(id: String) {
        guard let element = buttonElementsByID[id] else {
            #if DEBUG
            print("MirageControl: ContextObserver ignoring stale action \(id)")
            #endif
            return
        }
        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        #if DEBUG
        if err != .success {
            print("MirageControl: ContextObserver AXPress failed (\(err.rawValue)) for \(id)")
        }
        #endif
    }

    // MARK: - App attach / detach

    private func attach(to app: NSRunningApplication) {
        // Only observe regular user-facing apps. Agents/menu-bar apps rarely
        // host modal dialogs the user cares about, and observing them is
        // noise.
        guard app.activationPolicy == .regular,
              app.processIdentifier != currentPID else {
            // If the newly activated app is our own menu-bar extra there's
            // no dialog context worth showing — clear and bail.
            if app.processIdentifier != currentPID {
                detach()
                updateSnapshot(.none)
            }
            return
        }

        #if DEBUG
        print("MirageControl: ContextObserver attaching to \(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "?")]")
        #endif

        detach()

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        currentPID = pid
        currentAppElement = axApp

        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, ContextObserver.axCallback, &observer)
        guard createErr == .success, let observer else {
            #if DEBUG
            print("MirageControl: ContextObserver failed to create AXObserver for pid \(pid): \(createErr.rawValue)")
            #endif
            // We still want to at least take a snapshot of the current state,
            // even if we can't subscribe to updates.
            scheduleRecompute()
            return
        }
        currentObserver = observer

        // The run loop source MUST be installed before we add any
        // notifications — otherwise `AXObserverAddNotification` returns
        // `kAXErrorCannotComplete (-25204)` because AX has no way to deliver
        // callbacks yet.
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in Self.appNotifications {
            let err = AXObserverAddNotification(observer, axApp, note as CFString, refcon)
            #if DEBUG
            if err != .success && err != .notificationAlreadyRegistered {
                print("MirageControl: ContextObserver could not add \(note): \(err.rawValue)")
            }
            #endif
        }

        // Register per-window sheet / destruction notifications on the
        // current focused window so we learn when a sheet appears.
        if let focused: AXUIElement = Self.copyAttribute(axApp, kAXFocusedWindowAttribute) {
            registerWindowNotifications(on: focused, observer: observer, refcon: refcon)
        }

        scheduleRecompute()
    }

    private func detach() {
        if let observer = currentObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        currentObserver = nil
        currentAppElement = nil
        currentPID = nil
    }

    private func registerWindowNotifications(
        on window: AXUIElement,
        observer: AXObserver,
        refcon: UnsafeMutableRawPointer
    ) {
        for note in Self.windowNotifications {
            let err = AXObserverAddNotification(observer, window, note as CFString, refcon)
            #if DEBUG
            if err != .success && err != .notificationAlreadyRegistered {
                // Not fatal — some windows reject some notifications.
            }
            #endif
        }
    }

    // MARK: - AX callback

    /// AX element refs are CoreFoundation objects that are safe to pass
    /// across threads (Apple explicitly documents this in AXUIElement.h),
    /// but Swift 6's concurrency checker can't prove that on its own. This
    /// wrapper lets us hop elements back onto the MainActor without a
    /// `Sendable` warning.
    private struct AXElementBox: @unchecked Sendable {
        let element: AXUIElement
    }

    /// Static C trampoline; unpacks `refcon` and hops to the main actor.
    private static let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let me = Unmanaged<ContextObserver>.fromOpaque(refcon).takeUnretainedValue()
        let noteName = notification as String
        let box = AXElementBox(element: element)
        Task { @MainActor in
            me.handleAXNotification(noteName, element: box.element)
        }
    }

    private func handleAXNotification(_ name: String, element: AXUIElement) {
        #if DEBUG
        print("MirageControl: ContextObserver AX notification \(name)")
        if name == "AXSheetCreated" {
            let role: String = Self.copyAttribute(element, kAXRoleAttribute) ?? "?"
            let subrole: String = Self.copyAttribute(element, kAXSubroleAttribute) ?? "-"
            print("MirageControl:   sheet element role=\(role) subrole=\(subrole)")
            Self.dumpAXTree(element, depth: 1, limit: 3)
        }
        #endif
        // When focus moves to a new window, subscribe to its per-window
        // notifications so we catch sheet creation inside it.
        if name == kAXFocusedWindowChangedNotification as String
            || name == kAXMainWindowChangedNotification as String
            || name == kAXWindowCreatedNotification as String {
            if let observer = currentObserver {
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                registerWindowNotifications(on: element, observer: observer, refcon: refcon)
            }
        }
        scheduleRecompute()
    }

    // MARK: - Recompute (debounced)

    private func scheduleRecompute() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.recompute()
            }
        }
    }

    private func recompute() {
        guard let app = currentAppElement else {
            updateSnapshot(.none)
            return
        }

        let snapshot = Self.buildSnapshot(for: app) { [weak self] table in
            self?.buttonElementsByID = table
        }
        updateSnapshot(snapshot)
    }

    private func updateSnapshot(_ snapshot: UIContextSnapshot) {
        // Dedupe — identical snapshots shouldn't thrash the iPad UI.
        guard snapshot != latestSnapshot else { return }
        latestSnapshot = snapshot

        if case .none = snapshot {
            buttonElementsByID.removeAll()
        }

        #if DEBUG
        switch snapshot {
        case .none:
            print("MirageControl: ContextObserver snapshot = .none")
        case .dialog(let ctx):
            print("MirageControl: ContextObserver snapshot = dialog '\(ctx.title ?? "?")' with \(ctx.buttons.count) button(s)")
        }
        #endif

        let msg = ControlMessage.uiContextUpdate(snapshot: snapshot)
        let data: Data
        do {
            data = try JSONEncoder().encode(msg)
        } catch {
            #if DEBUG
            print("MirageControl: ContextObserver ❌ failed to encode snapshot: \(error)")
            #endif
            return
        }

        #if DEBUG
        print("MirageControl: ContextObserver 📤 broadcasting \(data.count)B to \(connections.count) peer(s)")
        #endif

        // Capture by value so each send task has a stable reference.
        let payload = data
        let peers = Array(connections.values)
        for handle in peers {
            Task {
                do {
                    try await handle.send(payload)
                    #if DEBUG
                    print("MirageControl: ContextObserver ✅ sent \(payload.count)B")
                    #endif
                } catch {
                    #if DEBUG
                    print("MirageControl: ContextObserver ❌ send failed: \(error)")
                    #endif
                }
            }
        }
    }

    // MARK: - Snapshot builder (pure over AX)

    /// Walks the frontmost app's focused window, looking for a dialog or
    /// sheet, and emits a `UIContextSnapshot` plus a fresh AX element map.
    /// The `store` callback receives the populated map so the singleton
    /// can update its lookup table under MainActor isolation.
    private static func buildSnapshot(
        for app: AXUIElement,
        store: (_ table: [String: AXUIElement]) -> Void
    ) -> UIContextSnapshot {
        // 1. Find a candidate dialog root. We look in four places, in
        //    priority order — each app framework reports modal surfaces
        //    slightly differently:
        //
        //      a. `AXSheets` array on the focused window (AppKit attached
        //         sheet — e.g. save panel).
        //      b. Direct `AXSheet`-role child of the focused window (what
        //         SwiftUI + some modern apps actually expose — AXSheets
        //         often returns empty even when a sheet is visible).
        //      c. The focused window itself has a dialog subrole
        //         (free-standing `NSAlert`).
        //      d. Any top-level window with dialog subrole (alerts that
        //         don't grab focus in the AX sense).
        guard let focused: AXUIElement = copyAttribute(app, kAXFocusedWindowAttribute) else {
            #if DEBUG
            print("MirageControl: ContextObserver no focused window")
            #endif
            store([:])
            return .none
        }

        let focusedRole: String = copyAttribute(focused, kAXRoleAttribute) ?? "?"
        let focusedSubrole: String = copyAttribute(focused, kAXSubroleAttribute) ?? "?"

        let dialogRoot: AXUIElement
        var source = "unknown"

        // When a sheet grabs focus (TextEdit's save prompt, NSSavePanel, and
        // many SwiftUI sheets), `AXFocusedWindow` on the app returns the
        // sheet itself — its role is `AXSheet`, not `AXWindow`. Handle that
        // case first.
        if focusedRole == (kAXSheetRole as String) {
            dialogRoot = focused
            source = "focused-role=AXSheet"
        } else if let sheets: [AXUIElement] = copyAttribute(focused, "AXSheets"),
                  let sheet = sheets.first {
            dialogRoot = sheet
            source = "AXSheets"
        } else if let sheetChild = firstChild(
                    of: focused, matchingRole: kAXSheetRole as String, depth: 0, limit: 3
                  ) {
            dialogRoot = sheetChild
            source = "child-role=AXSheet"
        } else if focusedSubrole == "AXDialog" || focusedSubrole == "AXSystemDialog" {
            dialogRoot = focused
            source = "focused-subrole=\(focusedSubrole)"
        } else if isModal(focused) {
            dialogRoot = focused
            source = "focused-AXModal"
        } else if let groupDialog = firstChild(
                    ofGroupWithDialogSubrole: focused, depth: 0, limit: 4
                  ) {
            // Some SwiftUI apps (System Settings is a notable culprit)
            // hoist their alert/confirm content into an `AXGroup` with
            // subrole `AXDialog` rather than a real `AXSheet` window.
            dialogRoot = groupDialog
            source = "child-group-dialog"
        } else if let modalWindow = firstModalWindow(in: app) {
            dialogRoot = modalWindow
            source = "top-level-dialog"
        } else {
            #if DEBUG
            let childSummary = summarizeChildren(of: focused, depth: 1, limit: 8)
            print("MirageControl: ContextObserver no dialog found | focused role=\(focusedRole) subrole=\(focusedSubrole) | children: \(childSummary)")
            #endif
            store([:])
            return .none
        }

        #if DEBUG
        print("MirageControl: ContextObserver found dialog via \(source)")
        dumpAXTree(dialogRoot, depth: 0, limit: 4)
        #endif

        // 2. Metadata
        let title: String? = copyAttribute(dialogRoot, kAXTitleAttribute)
        let message: String? = firstStaticText(under: dialogRoot, depth: 0, limit: 4)

        // 3. Default / cancel references — used to tag individual buttons.
        let defaultBtn: AXUIElement? = copyAttribute(dialogRoot, kAXDefaultButtonAttribute)
        let cancelBtn: AXUIElement? = copyAttribute(dialogRoot, kAXCancelButtonAttribute)

        // 4. Collect buttons (bounded).
        var raw: [(AXUIElement, String)] = []
        collectButtons(root: dialogRoot, depth: 0, into: &raw)
        guard !raw.isEmpty else {
            store([:])
            return .none
        }

        var table: [String: AXUIElement] = [:]
        var buttons: [DialogButton] = []
        for (elem, btnTitle) in raw {
            let id = UUID().uuidString
            table[id] = elem
            buttons.append(DialogButton(
                id: id,
                title: btnTitle,
                isDefault: defaultBtn.map { CFEqual(elem, $0) } ?? false,
                isCancel: cancelBtn.map { CFEqual(elem, $0) } ?? false
            ))
        }

        store(table)

        return .dialog(DialogContext(
            revision: UUID().uuidString,
            title: title,
            message: message,
            buttons: buttons
        ))
    }

    // MARK: - Debug

    #if DEBUG
    /// Prints the AX role tree rooted at `element` to the given depth.
    /// Used to diagnose why a dialog didn't yield the expected buttons.
    private static func dumpAXTree(_ element: AXUIElement, depth: Int, limit: Int) {
        guard depth < limit else { return }
        let role: String = copyAttribute(element, kAXRoleAttribute) ?? "?"
        let subrole: String = copyAttribute(element, kAXSubroleAttribute) ?? "-"
        let title: String = copyAttribute(element, kAXTitleAttribute) ?? ""
        let indent = String(repeating: "  ", count: depth)
        print("MirageControl:   \(indent)[\(role) / \(subrole)] '\(title)'")
        if let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) {
            for c in children.prefix(8) {
                dumpAXTree(c, depth: depth + 1, limit: limit)
            }
        }
    }
    #endif

    // MARK: - AX helpers

    /// Shallow search for the first direct-or-near-descendant child with
    /// the given role. Used to find attached sheets that don't show up in
    /// the window's `AXSheets` attribute.
    private static func firstChild(
        of element: AXUIElement,
        matchingRole role: String,
        depth: Int,
        limit: Int
    ) -> AXUIElement? {
        guard depth < limit else { return nil }
        guard let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) else {
            return nil
        }
        for child in children {
            let childRole: String? = copyAttribute(child, kAXRoleAttribute)
            if childRole == role { return child }
            if let nested = firstChild(of: child, matchingRole: role, depth: depth + 1, limit: limit) {
                return nested
            }
        }
        return nil
    }

    /// Looks for an `AXGroup` with subrole `AXDialog` / `AXSystemDialog`
    /// anywhere within a bounded subtree. System Settings and several
    /// SwiftUI-on-AppKit apps use this pattern for confirmation prompts.
    private static func firstChild(
        ofGroupWithDialogSubrole element: AXUIElement,
        depth: Int,
        limit: Int
    ) -> AXUIElement? {
        guard depth < limit else { return nil }
        guard let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) else {
            return nil
        }
        for child in children {
            let role: String = copyAttribute(child, kAXRoleAttribute) ?? ""
            let subrole: String = copyAttribute(child, kAXSubroleAttribute) ?? ""
            if role == (kAXGroupRole as String),
               subrole == "AXDialog" || subrole == "AXSystemDialog" {
                return child
            }
            if let nested = firstChild(
                ofGroupWithDialogSubrole: child, depth: depth + 1, limit: limit
            ) {
                return nested
            }
        }
        return nil
    }

    /// Reads `kAXModalAttribute` on a window. SwiftUI sheets frequently set
    /// this even when they don't adopt the `AXSheet` role or dialog subrole.
    private static func isModal(_ element: AXUIElement) -> Bool {
        let raw: NSNumber? = copyAttribute(element, "AXModal")
        return raw?.boolValue ?? false
    }

    #if DEBUG
    /// One-line summary of a focused window's immediate (or near-immediate)
    /// children — used when we can't find a dialog so the log tells us what
    /// the app's structure actually looks like in AX terms.
    private static func summarizeChildren(
        of element: AXUIElement,
        depth: Int,
        limit: Int
    ) -> String {
        guard let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) else {
            return "<none>"
        }
        var summary: [String] = []
        for c in children.prefix(8) {
            let role: String = copyAttribute(c, kAXRoleAttribute) ?? "?"
            let subrole: String = copyAttribute(c, kAXSubroleAttribute) ?? "-"
            summary.append("\(role)/\(subrole)")
        }
        return "[" + summary.joined(separator: ", ") + "]"
    }
    #endif

    /// Scans all top-level windows of an app for a modal surface — a
    /// sheet (role `AXSheet`) or dialog-subrole window (free-standing
    /// alert that doesn't own AX focus). Also digs one level into each
    /// window to find attached sheets that didn't come up via `AXSheets`.
    private static func firstModalWindow(in app: AXUIElement) -> AXUIElement? {
        guard let windows: [AXUIElement] = copyAttribute(app, kAXWindowsAttribute) else {
            return nil
        }
        for win in windows {
            let role: String = copyAttribute(win, kAXRoleAttribute) ?? ""
            if role == (kAXSheetRole as String) { return win }
            let subrole: String = copyAttribute(win, kAXSubroleAttribute) ?? ""
            if subrole == "AXDialog" || subrole == "AXSystemDialog" { return win }
            if isModal(win) { return win }
            if let sheetChild = firstChild(
                of: win, matchingRole: kAXSheetRole as String, depth: 0, limit: 2
            ) {
                return sheetChild
            }
            if let groupDialog = firstChild(
                ofGroupWithDialogSubrole: win, depth: 0, limit: 4
            ) {
                return groupDialog
            }
        }
        return nil
    }

    /// Recursive, depth-bounded search for enabled `AXButton` descendants.
    /// Caps at 12 results so a pathological window can't stall the AX thread.
    private static func collectButtons(
        root: AXUIElement,
        depth: Int,
        into out: inout [(AXUIElement, String)]
    ) {
        guard depth < 8, out.count < 12 else { return }

        guard let children: [AXUIElement] = copyAttribute(root, kAXChildrenAttribute) else {
            return
        }
        for child in children {
            if out.count >= 12 { return }
            let role: String? = copyAttribute(child, kAXRoleAttribute)
            if role == (kAXButtonRole as String) {
                // `AXEnabled` returns a CFBoolean — bridge through NSNumber
                // because `as? Bool` doesn't always succeed on CFBoolean in
                // Swift 6. Absence of the attribute is treated as "enabled".
                let enabledRaw: NSNumber? = copyAttribute(child, kAXEnabledAttribute)
                if let e = enabledRaw, e.boolValue == false { continue }
                let title = buttonLabel(for: child)
                guard !title.isEmpty else { continue }
                out.append((child, title))
                // Buttons don't contain other buttons in any real dialog,
                // so we don't recurse into them.
            } else {
                collectButtons(root: child, depth: depth + 1, into: &out)
            }
        }
    }

    /// AX can name a button via title / description / identifier. Tries in
    /// order; returns empty string if none work so the caller can skip.
    private static func buttonLabel(for element: AXUIElement) -> String {
        if let t: String = copyAttribute(element, kAXTitleAttribute), !t.isEmpty { return t }
        if let d: String = copyAttribute(element, kAXDescriptionAttribute), !d.isEmpty { return d }
        if let id: String = copyAttribute(element, kAXIdentifierAttribute), !id.isEmpty { return id }
        return ""
    }

    /// Finds the first non-empty static-text descendant within a few levels
    /// of the dialog root. Used for the dialog body/message copy.
    private static func firstStaticText(
        under root: AXUIElement,
        depth: Int,
        limit: Int
    ) -> String? {
        guard depth < limit else { return nil }
        guard let children: [AXUIElement] = copyAttribute(root, kAXChildrenAttribute) else {
            return nil
        }
        for child in children {
            let role: String? = copyAttribute(child, kAXRoleAttribute)
            if role == (kAXStaticTextRole as String) {
                if let v: String = copyAttribute(child, kAXValueAttribute), !v.isEmpty {
                    return v
                }
                if let t: String = copyAttribute(child, kAXTitleAttribute), !t.isEmpty {
                    return t
                }
            }
            if let nested = firstStaticText(under: child, depth: depth + 1, limit: limit) {
                return nested
            }
        }
        return nil
    }

    /// Generic typed wrapper over `AXUIElementCopyAttributeValue`. Returns
    /// `nil` on failure or type mismatch — callers never see raw AXError.
    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success, let ref else { return nil }
        return ref as? T
    }

    // MARK: - Send

    private func send(_ snapshot: UIContextSnapshot, to handle: LoomConnectionHandle) async throws {
        let msg = ControlMessage.uiContextUpdate(snapshot: snapshot)
        try await handle.send(JSONEncoder().encode(msg))
    }
}

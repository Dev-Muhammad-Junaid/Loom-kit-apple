//
//  AppLauncher.swift
//  DeckHandMac
//

import AppKit
import Foundation

@MainActor
final class AppLauncher {
    static let shared = AppLauncher()
    private init() {}

    /// Brings `bundleID` to the foreground, launching it if it isn't already
    /// running. Returns `true` when the system accepts the activation request.
    ///
    /// We always route through `NSWorkspace.openApplication(at:)` rather than
    /// `NSRunningApplication.activate()`. On macOS 14+ a menu-bar background
    /// app like ours (`LSUIElement = true`) can't directly steal focus via
    /// `activate()` — the call returns success but the target app never
    /// actually comes forward. `NSWorkspace.openApplication(at:)` with
    /// `configuration.activates = true` is the documented path that works
    /// from background processes and on macOS 26 Tahoe.
    @discardableResult
    func launch(bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            #if DEBUG
            print("Deck Hand: ⚠️ No app URL for bundleID \(bundleID)")
            #endif
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return true
        } catch {
            #if DEBUG
            print("Deck Hand: ⚠️ Failed to open \(bundleID): \(error)")
            #endif
            return false
        }
    }

    /// Brings `bundleID` to the foreground, polls `frontmostApplication` until
    /// it matches, then sleeps briefly to let the key window settle so any
    /// keyboard events posted immediately afterwards actually land in the app.
    ///
    /// `settleDelay` (default 80 ms) matters more than it looks: without it,
    /// `CGEvent.post` sometimes fires while the target app's window is still
    /// in the middle of becoming key, and the first modifier gets swallowed.
    func activateAndWait(
        bundleID: String,
        timeout: TimeInterval = 1.0,
        settleDelay: TimeInterval = 0.08
    ) async {
        // Fast path: already frontmost — still give the caller the settle delay.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            return
        }

        _ = await launch(bundleID: bundleID)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #if DEBUG
        print("Deck Hand: ⚠️ \(bundleID) never became frontmost within \(timeout)s; sending shortcut anyway")
        #endif
    }
}

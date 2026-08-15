//
//  DeckHandAppDelegate.swift
//  DeckHandMac
//
//  Owns the menu-bar status item directly via NSStatusItem instead of
//  SwiftUI's MenuBarExtra.
//
//  MenuBarExtra works, but it gives us no handle on the underlying
//  NSStatusItem, so we can't set `behavior`, pin visibility, or size the
//  panel from AppKit. Owning the item keeps all of that explicit and lets
//  the popover derive its height from the SwiftUI content instead of a
//  hard-coded frame.
//
//  Note: if the icon is missing entirely, that is almost never this file.
//  See MenuBarStatusItems-macOS26.md — launching the executable directly
//  (Xcode's Run button) permanently breaks menu-bar registration for that
//  bundle identifier on macOS 26. Launch through LaunchServices instead.
//

import AppKit
import Loom
import LoomKit
import SwiftUI

@MainActor
final class DeckHandAppDelegate: NSObject, NSApplicationDelegate {
    /// The Loom runtime + receiver. Created here so its lifetime matches the
    /// app process (previously a SwiftUI @StateObject on MacHostApp).
    private let daemon = MacDaemon()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory = menu-bar utility, no Dock icon, doesn't steal focus.
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Stable autosave key so the menu bar tracks this one item across
        // launches instead of inventing fresh "Item-0" indices.
        item.autosaveName = "DeckHandStatusItem"
        // Empty behavior: the user can't drag the icon out of the menu bar,
        // and removal can never terminate the app.
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "cursorarrow.rays",
                accessibilityDescription: "Deck Hand"
            )
            image?.isTemplate = true // adapts to the transparent Tahoe menu bar
            button.image = image
            // Fallback so the item can never collapse to zero width (and thus
            // be invisible) if the SF Symbol fails to resolve on this OS.
            if image == nil {
                button.title = "Deck Hand"
            }
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient // closes when you click away, like a menu-bar panel
        // Size from the SwiftUI content. MacMenuBarView fixes its width but not
        // its height, so a hard-coded contentSize leaves Auto Layout with an
        // ambiguous vertical dimension.
        let hosting = NSHostingController(rootView: rootView())
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover
    }

    /// Keep the process alive even with no visible windows — it's a resident
    /// menu-bar agent.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @ViewBuilder
    private func rootView() -> some View {
        if let container = daemon.container {
            MacMenuBarView(receiver: daemon.receiver)
                .loomContainer(container, autostart: false)
                .environmentObject(DeviceAuthorizationManager.shared)
                .environmentObject(daemon)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Deck Hand failed to start")
                    .font(.headline)
                Text(daemon.fatalStartupError ?? "Unknown error")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(width: 280)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

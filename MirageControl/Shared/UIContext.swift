//
//  UIContext.swift
//  MirageControl – Shared
//
//  Wire model for "what's currently interactable on the Mac". Phase 1 covers
//  modal dialogs / sheets / alerts: the Mac's Accessibility-backed
//  `ContextObserver` snapshots the buttons inside a dialog and sends them
//  to the iPad, which renders them as tappable chips in the Quick Actions
//  bar. The iPad echoes back the opaque `DialogButton.id` via
//  `ControlMessage.triggerContextAction`; the Mac looks up the stored
//  `AXUIElement` for that ID and performs `kAXPressAction`.
//
//  Snapshot IDs are invalidated every time a new snapshot is emitted, so
//  a late tap after the dialog has closed is a safe no-op on the Mac.
//

import Foundation

public enum UIContextSnapshot: Codable, Hashable, Sendable {
    /// No interesting context — fall back to the per-app shortcut chips.
    case none
    /// A modal dialog / sheet / alert is visible on the frontmost app.
    case dialog(DialogContext)
}

public struct DialogContext: Codable, Hashable, Sendable {
    /// Snapshot revision — iPad only renders actions whose parent snapshot
    /// revision matches the latest one it's seen. Prevents stale taps from
    /// reaching the Mac after a dialog has been dismissed.
    public let revision: String
    /// Title of the dialog / sheet, if AX exposed one. Often `nil` for
    /// system alerts that embed their title in a label instead.
    public let title: String?
    /// Optional body text (AX `description` / first static-text child).
    /// iPad may show this as a small caption above the button row.
    public let message: String?
    /// Buttons in tab order, left-to-right.
    public let buttons: [DialogButton]

    public init(revision: String, title: String?, message: String?, buttons: [DialogButton]) {
        self.revision = revision
        self.title = title
        self.message = message
        self.buttons = buttons
    }
}

public struct DialogButton: Codable, Hashable, Sendable, Identifiable {
    /// Opaque Mac-side handle (synthetic UUID, scoped to the snapshot
    /// revision). Echoed back in `triggerContextAction`.
    public let id: String
    public let title: String
    /// `true` for the AX `defaultButton` (⏎). Rendered with violet tint.
    public let isDefault: Bool
    /// `true` for the AX `cancelButton` (⎋). Rendered with subtle
    /// destructive styling.
    public let isCancel: Bool

    public init(id: String, title: String, isDefault: Bool, isCancel: Bool) {
        self.id = id
        self.title = title
        self.isDefault = isDefault
        self.isCancel = isCancel
    }
}

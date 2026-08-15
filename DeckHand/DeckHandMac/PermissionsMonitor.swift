//
//  PermissionsMonitor.swift
//  DeckHandMac
//
//  Live TCC permission status for the menu bar panel.
//
//  "I enabled it in System Settings but the app still can't do anything"
//  has two usual causes this view makes visible and fixable:
//
//   1. The toggle was enabled for a *previous build* of the app. With
//      ad-hoc / development signing every rebuild changes the binary's
//      identity, so TCC's existing grant can silently stop matching.
//      The fix is to remove the app from the System Settings list and
//      re-add it (the per-row buttons open the exact pane).
//   2. Screen Recording grants only take effect after the app is
//      relaunched — macOS does not apply them to a running process.
//
//  Statuses are re-checked every time the panel appears and every 2 s
//  while it stays open, so the rows update live as the user flips
//  toggles in System Settings.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import UserNotifications

@MainActor
final class PermissionsMonitor: ObservableObject {
    static let shared = PermissionsMonitor()

    enum Status: Equatable {
        case granted
        case denied
        /// Granted but needs an app relaunch to take effect (Screen
        /// Recording behaves this way when toggled while running).
        case unknown
    }

    @Published private(set) var accessibility: Status = .unknown
    @Published private(set) var screenRecording: Status = .unknown
    @Published private(set) var notifications: Status = .unknown

    /// Set when the Settings toggle reads "on" but actual capture is
    /// denied — the stale-grant / needs-relaunch state. Cleared once a
    /// real capture probe succeeds.
    @Published private(set) var screenRecordingNeedsRelaunch = false

    private var probeInFlight = false

    private init() {
        refresh()
    }

    /// Re-evaluates every permission. Cheap — safe to call on a 2 s tick
    /// while the menu bar panel is open.
    func refresh() {
        accessibility = AXIsProcessTrusted() ? .granted : .denied

        // CGPreflightScreenCaptureAccess only reflects the Settings toggle,
        // which can be bound to a PREVIOUS build of the app (dev signing
        // changes the binary identity every rebuild). The toggle then reads
        // "on" while actual capture is denied. Ground truth is an actual
        // ScreenCaptureKit content query — probe it and believe the probe.
        let toggleSaysGranted = CGPreflightScreenCaptureAccess()
        if !probeInFlight {
            probeInFlight = true
            Task { [weak self] in
                let actuallyWorks: Bool
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true
                    )
                    actuallyWorks = true
                } catch {
                    actuallyWorks = false
                }
                await MainActor.run {
                    guard let self else { return }
                    self.probeInFlight = false
                    self.screenRecording = actuallyWorks ? .granted : .denied
                    // Toggle on + capture denied = stale grant for an older
                    // build, or grant not applied to the running process —
                    // both fixed by remove/re-add + relaunch.
                    self.screenRecordingNeedsRelaunch = toggleSaysGranted && !actuallyWorks
                }
            }
        }

        // `@Sendable` is load-bearing: UserNotifications calls this back on
        // its own internal queue (UNUserNotificationServiceConnection
        // .call-out), but this type is @MainActor, so without the annotation
        // Swift 6 infers the closure as main-actor-isolated and the runtime
        // executor check (`swift_task_isCurrentExecutorImpl`) traps with
        // `dispatch_assert_queue_fail` the moment it runs off-main. Marking
        // it @Sendable makes it nonisolated; the Task hop below does the
        // main-actor write.
        UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
            let status: Status = switch settings.authorizationStatus {
            case .authorized, .provisional: .granted
            case .denied: .denied
            default: .unknown
            }
            Task { @MainActor in
                self.notifications = status
            }
        }
    }

    // MARK: - Actions

    /// Triggers the system Accessibility prompt (first time) or opens the
    /// Settings pane (after a denial, the prompt no longer shows).
    func fixAccessibility() {
        if !AXIsProcessTrusted() {
            InputInjector.shared.requestAccessibility()
            openSettings(pane: "Privacy_Accessibility")
        }
        refresh()
    }

    /// Triggers the Screen Recording prompt / registers the app in the
    /// Settings list, then opens the pane.
    func fixScreenRecording() {
        CGRequestScreenCaptureAccess()
        openSettings(pane: "Privacy_ScreenCapture")
        refresh()
    }

    func fixNotifications() {
        DeviceAuthorizationManager.shared.requestNotificationPermissions()
        openSettings(pane: "Privacy_Notifications")
        refresh()
    }

    func relaunchApp() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Same reason as getNotificationSettings above: NSWorkspace invokes
        // this completion on an arbitrary queue, so it must be @Sendable to
        // avoid the main-actor executor trap under Swift 6.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { @Sendable _, _ in
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func openSettings(pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

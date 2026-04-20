//
//  RunningAppMonitor.swift
//  MirageControlMac
//
//  Tracks user-facing running apps and broadcasts their bundle IDs in
//  Cmd+Tab order (most-recently-activated first) to every connected iPad.
//  The iPad uses this list to render an app-switcher menu next to the
//  active-app pill in the Quick Actions bar.
//
//  We intentionally broadcast only bundle IDs — the iPad already has a
//  cached `installedApps` catalog with icons and display names, so there
//  is no reason to re-send the same icon bytes on every launch/terminate.
//

import AppKit
import Combine
import Foundation
import LoomKit

@MainActor
final class RunningAppMonitor {
    static let shared = RunningAppMonitor()

    private var cancellables = Set<AnyCancellable>()
    private var connections: [UUID: LoomConnectionHandle] = [:]

    /// Bundle IDs of running user-facing apps in most-recent-activation order.
    /// Head of the array is the frontmost app.
    private var orderedBundleIDs: [String] = []

    private init() {
        seedFromCurrentlyRunning()

        let center = NSWorkspace.shared.notificationCenter

        center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { await self?.handleLaunch(app) }
            }
            .store(in: &cancellables)

        center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier else { return }
                Task { await self?.handleTerminate(bundleID: id) }
            }
            .store(in: &cancellables)

        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier else { return }
                Task { await self?.handleActivate(bundleID: id) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Connection wiring

    func addConnection(_ handle: LoomConnectionHandle, id: UUID) {
        connections[id] = handle
        Task { try? await send(orderedBundleIDs, to: handle) }
    }

    func removeConnection(id: UUID) {
        connections.removeValue(forKey: id)
    }

    // MARK: - Event handlers

    private func seedFromCurrentlyRunning() {
        // Running apps already sorted frontmost-first: put `frontmostApplication`
        // at index 0, then everything else in launch order as a reasonable
        // approximation — activation events will fix up the order as the user
        // Cmd-Tabs around.
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var ids: [String] = []
        if let frontID { ids.append(frontID) }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != frontID else { continue }
            ids.append(id)
        }
        orderedBundleIDs = ids
    }

    private func handleLaunch(_ app: NSRunningApplication) async {
        guard app.activationPolicy == .regular,
              let id = app.bundleIdentifier,
              !orderedBundleIDs.contains(id) else { return }
        // New apps enter below the frontmost — they haven't been activated yet.
        if orderedBundleIDs.isEmpty {
            orderedBundleIDs = [id]
        } else {
            orderedBundleIDs.insert(id, at: min(1, orderedBundleIDs.count))
        }
        await broadcast()
    }

    private func handleTerminate(bundleID: String) async {
        guard let idx = orderedBundleIDs.firstIndex(of: bundleID) else { return }
        orderedBundleIDs.remove(at: idx)
        await broadcast()
    }

    private func handleActivate(bundleID: String) async {
        if let idx = orderedBundleIDs.firstIndex(of: bundleID) {
            orderedBundleIDs.remove(at: idx)
        }
        orderedBundleIDs.insert(bundleID, at: 0)
        await broadcast()
    }

    // MARK: - Broadcast

    private func broadcast() async {
        let snapshot = orderedBundleIDs
        for handle in connections.values {
            try? await send(snapshot, to: handle)
        }
    }

    private func send(_ bundleIDs: [String], to handle: LoomConnectionHandle) async throws {
        let msg = ControlMessage.runningAppsUpdate(bundleIDs: bundleIDs)
        try await handle.send(JSONEncoder().encode(msg))
    }
}

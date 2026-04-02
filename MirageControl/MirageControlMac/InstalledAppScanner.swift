//
//  InstalledAppScanner.swift
//  MirageControlMac
//

import AppKit
import Foundation

/// Scans macOS application directories and produces a lightweight catalog
/// of installed user-facing apps with compressed icon data.
@MainActor
final class InstalledAppScanner {
    static let shared = InstalledAppScanner()
    private init() {}

    /// Cached result so we don't rescan on every iPad connect.
    private var cachedApps: [InstalledAppInfo]?
    private var lastScanDate: Date?

    /// Returns cached apps if scanned within the last 5 minutes, otherwise rescans.
    func installedApps() -> [InstalledAppInfo] {
        if let cached = cachedApps,
           let lastScan = lastScanDate,
           Date().timeIntervalSince(lastScan) < 300 {
            return cached
        }
        let apps = scanInstalledApps()
        cachedApps = apps
        lastScanDate = Date()
        return apps
    }

    /// Force-clears the cache so the next request triggers a fresh scan.
    func invalidateCache() {
        cachedApps = nil
        lastScanDate = nil
    }

    // MARK: - Scanning

    private func scanInstalledApps() -> [InstalledAppInfo] {
        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications"),
        ]

        var seen = Set<String>()   // deduplicate by bundleID
        var apps: [InstalledAppInfo] = []

        for dir in appDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                guard let info = appInfo(at: url), !seen.contains(info.bundleID) else {
                    continue
                }
                seen.insert(info.bundleID)
                apps.append(info)
            }
        }

        let sorted = apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        // Cap at 50 apps to keep the initial payload small
        return Array(sorted.prefix(50))
    }

    /// Reads bundle metadata and extracts a small icon for the given .app URL.
    /// Returns `nil` for background-only apps and system frameworks.
    private func appInfo(at url: URL) -> InstalledAppInfo? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return nil
        }

        // Filter out background-only / agent / menu-bar-only apps
        let infoDict = bundle.infoDictionary ?? [:]
        if infoDict["LSBackgroundOnly"] as? Bool == true { return nil }
        if infoDict["LSUIElement"] as? Bool == true { return nil }

        // Get display name (prefer CFBundleDisplayName, fall back to CFBundleName, then filename)
        let displayName = infoDict["CFBundleDisplayName"] as? String
            ?? infoDict["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent

        // Skip apps with no meaningful name
        if displayName.isEmpty { return nil }

        // Get icon as compressed JPEG data
        let iconData = compressedIcon(for: url)

        return InstalledAppInfo(
            bundleID: bundleID,
            displayName: displayName,
            iconData: iconData
        )
    }

    /// Reads the app icon via NSWorkspace, resizes to 64×64, and returns JPEG data.
    private func compressedIcon(for appURL: URL) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let targetSize = NSSize(width: 64, height: 64)

        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: icon.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

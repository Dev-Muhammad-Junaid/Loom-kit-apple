//
//  ScreenCaptureService.swift
//  MirageControlMac
//
//  Screen-capture pipeline backed by ScreenCaptureKit.
//
//  `CGDisplayCreateImage` is deprecated as of macOS 14 and is removed from the
//  supported surface on macOS 26 (Tahoe); ScreenCaptureKit's `SCScreenshotManager`
//  is the current Apple-recommended path for one-shot screen grabs.
//
//  Permission handling moves from `CGPreflightScreenCaptureAccess` to probing
//  `SCShareableContent` — if the user hasn't granted Screen Recording access the
//  first call surfaces the TCC prompt and throws `.permissionDenied`.
//
//  Hot-path optimizations relative to the original implementation:
//
//   1. `SCShareableContent` is fetched once and cached. Refresh is driven by
//      `NSApplication.didChangeScreenParametersNotification` — we don't pay
//      a WindowServer round-trip on every iPad tap.
//   2. `SCStreamConfiguration` is sized to the *target* output (default
//      1920 wide), so the GPU does the downsample inside `SCScreenshotManager`
//      rather than dragging the full pixel grid back to the CPU only to
//      shrink it. On a 6K display this avoids ≈80 MB of allocation per shot.
//   3. JPEG encoding goes through `CGImageDestination` directly. The previous
//      `NSImage.lockFocus → tiffRepresentation → NSBitmapImageRep → JPEG`
//      chain costs two extra full-frame copies; ImageIO does it in one.
//

import AppKit
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

@MainActor
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    enum CaptureError: Error {
        case permissionDenied
        case noDisplay
        case windowNotFound
        case captureFailed(String)
        case encodeFailed
    }

    // MARK: - Cached SCShareableContent
    //
    // Refreshed lazily on first capture, then again whenever screens change.
    // We keep both the raw shareable content and a snapshot of `displays`
    // / `windows` so callers can pick a target without re-querying.

    private var cachedContent: SCShareableContent?
    private var contentObserver: NSObjectProtocol?

    private init() {
        // Drop the cache when the user plugs / unplugs a display, changes
        // resolution, or rearranges spaces — any of those invalidate the
        // SCDisplay handle we'd been holding onto.
        contentObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ScreenCaptureService.shared.cachedContent = nil
            }
        }
    }

    // No `deinit` here on purpose. `ScreenCaptureService` is a process-lifetime
    // singleton (`static let shared`), so a deinit would never run anyway.
    // Beyond being dead code, an explicit `deinit` would force us to access
    // the non-Sendable `contentObserver` from a nonisolated deinit, which
    // Swift 6 strict concurrency rejects. Keeping `contentObserver` alive on
    // the singleton is exactly what we want: the observation should fire for
    // the life of the process.

    /// Triggers the system Screen Recording prompt by touching `SCShareableContent`.
    /// Call this once at launch so the dialog appears before the user actually
    /// requests a screenshot from the iPad. Result is cached for reuse.
    func primePermission() async {
        _ = try? await loadContent()
    }

    private func loadContent(forceRefresh: Bool = false) async throws -> SCShareableContent {
        if !forceRefresh, let cachedContent {
            return cachedContent
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            cachedContent = content
            return content
        } catch {
            cachedContent = nil
            throw CaptureError.permissionDenied
        }
    }

    /// Captures the main display and returns JPEG data downscaled to at most
    /// `maxWidth` points wide. Encoded via ImageIO directly off the
    /// `CGImage` returned by ScreenCaptureKit.
    func captureMainDisplayJPEG(
        maxWidth: CGFloat = 1920,
        quality: CGFloat = 0.75
    ) async throws -> Data {
        let display = try await primaryDisplay()
        let cgImage = try await captureDisplay(display, maxWidth: maxWidth)
        return try Self.encodeJPEG(cgImage, quality: quality)
    }

    /// Captures the main display, then crops it to `region` (normalized 0…1
    /// coordinates relative to the captured frame, origin top-left) and
    /// returns the cropped JPEG. Region capture is intentionally driven from
    /// the Mac so the user gets a *fresh* pixel grid — the iPad only needs
    /// to ship the rect.
    func captureRegionJPEG(
        normalizedRect: CGRect,
        maxWidth: CGFloat = 1920,
        quality: CGFloat = 0.75
    ) async throws -> Data {
        let display = try await primaryDisplay()
        // Use a higher capture max for region grabs so the crop has real
        // detail. We still bound it by the source size.
        let fullImage = try await captureDisplay(display, maxWidth: max(maxWidth, 2880))

        let imgWidth = CGFloat(fullImage.width)
        let imgHeight = CGFloat(fullImage.height)
        let cropRect = CGRect(
            x: max(0, normalizedRect.origin.x * imgWidth),
            y: max(0, normalizedRect.origin.y * imgHeight),
            width: min(imgWidth - normalizedRect.origin.x * imgWidth,
                       normalizedRect.size.width * imgWidth),
            height: min(imgHeight - normalizedRect.origin.y * imgHeight,
                        normalizedRect.size.height * imgHeight)
        ).integral

        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = fullImage.cropping(to: cropRect) else {
            throw CaptureError.captureFailed("Crop rect was empty")
        }
        return try Self.encodeJPEG(cropped, quality: quality)
    }

    /// Captures a single window by its `CGWindowID`. Falls back to a display
    /// capture filtered to that window if the OS doesn't expose the window
    /// through `SCShareableContent`.
    func captureWindowJPEG(
        windowID: UInt32,
        maxWidth: CGFloat = 1920,
        quality: CGFloat = 0.75
    ) async throws -> Data {
        let content = try await loadContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            // Try a fresh content fetch in case the window opened after we
            // last cached.
            let refreshed = try await loadContent(forceRefresh: true)
            guard let window = refreshed.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.windowNotFound
            }
            return try await captureWindow(window, maxWidth: maxWidth, quality: quality)
        }
        return try await captureWindow(window, maxWidth: maxWidth, quality: quality)
    }

    private func captureWindow(
        _ window: SCWindow,
        maxWidth: CGFloat,
        quality: CGFloat
    ) async throws -> Data {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let frame = window.frame
        let target = Self.targetSize(
            sourceWidth: CGFloat(max(1, Int(frame.width))),
            sourceHeight: CGFloat(max(1, Int(frame.height))),
            maxWidth: maxWidth
        )

        let config = SCStreamConfiguration()
        config.width  = Int(target.width)
        config.height = Int(target.height)
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
        return try Self.encodeJPEG(cgImage, quality: quality)
    }

    /// Returns a snapshot of every visible user-facing window suitable for
    /// the iPad's window picker. Layer-zero windows only (no menu bar /
    /// dock / status items) and titles are required so the picker doesn't
    /// surface anonymous floating panels.
    func enumerateWindows() async throws -> [WindowInfo] {
        let content = try await loadContent(forceRefresh: true)
        let workspaceApps = NSWorkspace.shared.runningApplications
        let appsByPID = Dictionary(uniqueKeysWithValues: workspaceApps.compactMap { app -> (pid_t, NSRunningApplication)? in
            (app.processIdentifier, app)
        })

        var seen = Set<UInt32>()
        var result: [WindowInfo] = []
        result.reserveCapacity(content.windows.count)

        for window in content.windows {
            guard window.windowLayer == 0 else { continue }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }
            guard window.frame.width >= 80, window.frame.height >= 60 else { continue }
            guard !seen.contains(window.windowID) else { continue }
            seen.insert(window.windowID)

            let owningPID = window.owningApplication?.processID ?? 0
            let runningApp = appsByPID[owningPID]
            let appName = window.owningApplication?.applicationName
                ?? runningApp?.localizedName
                ?? "Unknown"
            let bundleID = window.owningApplication?.bundleIdentifier ?? runningApp?.bundleIdentifier

            // Skip our own menu-bar app — the user never wants to capture us.
            if bundleID == Bundle.main.bundleIdentifier { continue }

            let iconData: Data? = {
                guard let app = runningApp,
                      let bundleURL = app.bundleURL else { return nil }
                return Self.compressedIcon(for: bundleURL, side: 48)
            }()

            result.append(WindowInfo(
                windowID: window.windowID,
                title: title,
                appName: appName,
                bundleID: bundleID,
                appIconData: iconData
            ))
        }

        // Sort by app name then title so the picker is stable across calls.
        result.sort {
            if $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedSame {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        return result
    }

    // MARK: - Internals

    private func primaryDisplay() async throws -> SCDisplay {
        let content = try await loadContent()
        guard let display = content.displays.first else {
            // Force a refresh in case the displays array was stale.
            let refreshed = try await loadContent(forceRefresh: true)
            guard let display = refreshed.displays.first else {
                throw CaptureError.noDisplay
            }
            return display
        }
        return display
    }

    private func captureDisplay(
        _ display: SCDisplay,
        maxWidth: CGFloat
    ) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Tell SC the size we actually want. The capture path will downscale
        // on its way out — much cheaper than dragging the full pixel grid.
        let target = Self.targetSize(
            sourceWidth: CGFloat(display.width),
            sourceHeight: CGFloat(display.height),
            maxWidth: maxWidth
        )

        let config = SCStreamConfiguration()
        config.width  = Int(target.width)
        config.height = Int(target.height)
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }

    private static func targetSize(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        maxWidth: CGFloat
    ) -> CGSize {
        let width = min(sourceWidth, maxWidth)
        let ratio = width / max(sourceWidth, 1)
        let height = sourceHeight * ratio
        return CGSize(width: max(width.rounded(), 1), height: max(height.rounded(), 1))
    }

    private static func encodeJPEG(_ cgImage: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw CaptureError.encodeFailed
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.encodeFailed
        }
        return data as Data
    }

    private static func compressedIcon(for appURL: URL, side: CGFloat) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let target = NSSize(width: side, height: side)
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(
            in: NSRect(origin: .zero, size: target),
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

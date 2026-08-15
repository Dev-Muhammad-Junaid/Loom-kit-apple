//
//  ScreenCaptureService.swift
//  DeckHandMac
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

    /// Captures the main display at full native resolution, then crops it
    /// to `normalizedRect` (0…1, origin top-left) and returns lossless PNG
    /// data. Region capture is intentionally driven from the Mac so the
    /// user gets a *fresh* pixel grid — the iPad only needs to ship the
    /// rect.
    ///
    /// The previous implementation downscaled the entire display to ~2880
    /// pixels wide *before* cropping. On a 5K display that meant the user's
    /// region had already been resampled by ~1.8× before they ever saw it,
    /// which is why region grabs looked soft and washed-out compared to
    /// macOS's built-in `Cmd+Shift+4`. We now grab the display at full
    /// native pixels and only downscale at the very end if the crop itself
    /// exceeds `maxWidth` — most user-selected regions are well under
    /// that, so they ship through pixel-for-pixel. PNG instead of JPEG
    /// keeps text and UI edges crisp (and matches the windowed-capture
    /// path so the on-device OCR handler sees the same encoding).
    func captureRegion(
        normalizedRect: CGRect,
        maxWidth: CGFloat = 2400
    ) async throws -> Data {
        let display = try await primaryDisplay()
        // Capture at full native pixels — no maxWidth cap. We'll downscale
        // *after* cropping if the crop is still too big to ship.
        let fullImage = try await captureDisplay(
            display,
            maxWidth: .greatestFiniteMagnitude
        )

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

        let finalImage = Self.downscale(cropped, maxWidth: maxWidth) ?? cropped
        return try Self.encodePNG(finalImage)
    }

    /// Captures a single window by its `CGWindowID`. The output mirrors
    /// macOS's native `Cmd+Shift+4 → Space → click` capture: WindowServer
    /// renders the window's drop shadow as part of the composite, and the
    /// surrounding shadow halo is encoded as transparent pixels in a PNG —
    /// no manual padding, no opaque background. That's why this path
    /// returns a PNG blob instead of a JPEG: JPEG can't carry alpha, and
    /// the shadow's transparent edges are exactly what makes the result
    /// look "premium".
    func captureWindowJPEG(
        windowID: UInt32,
        maxWidth: CGFloat = 2400,
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
            return try await captureWindow(window, maxWidth: maxWidth)
        }
        return try await captureWindow(window, maxWidth: maxWidth)
    }

    private func captureWindow(
        _ window: SCWindow,
        maxWidth: CGFloat
    ) async throws -> Data {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // SCContentFilter exposes `contentRect` and `pointPixelScale` on
        // macOS 14+, and they bake in the shadow margin once we've turned
        // shadows back on (see `ignoreShadowsSingleWindow` below). That
        // means we don't have to inflate the rect by hand or guess the
        // shadow size — WindowServer tells us the natural bounding box.
        let pixelScale: CGFloat
        let contentRect: CGRect
        if #available(macOS 14.0, *) {
            pixelScale = CGFloat(filter.pointPixelScale)
            contentRect = filter.contentRect
        } else {
            // Fallback that should never trigger given the 14.0 deployment
            // target; included so the call site stays branch-clean.
            pixelScale = NSScreen.main?.backingScaleFactor ?? 2.0
            contentRect = window.frame
        }

        let nativePixelWidth  = max(1, contentRect.width  * pixelScale)
        let nativePixelHeight = max(1, contentRect.height * pixelScale)

        // Down-scale only when the native pixel grid exceeds `maxWidth`.
        // PNG of a non-downscaled retina window is ~2-4 MB; that's fine
        // for the iPad over local Wi-Fi but oversized for OCR / preview,
        // so the cap stays useful.
        let downscale = min(1.0, maxWidth / nativePixelWidth)

        let config = SCStreamConfiguration()
        config.width  = Int((nativePixelWidth  * downscale).rounded())
        config.height = Int((nativePixelHeight * downscale).rounded())
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Transparent fill so empty halo around the shadow stays empty
        // instead of being painted with the system default (white).
        config.backgroundColor = .clear
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
            // Default for single-window captures is "ignore the shadow";
            // we want the opposite. Together with `backgroundColor = .clear`,
            // this is what gives us the macOS screenshot.app look.
            config.ignoreShadowsSingleWindow = false
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
        // PNG, not JPEG: the shadow halo is transparent and JPEG would
        // collapse it to an opaque rectangle.
        return try Self.encodePNG(cgImage)
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

    /// High-quality CGImage downscaler. Returns `nil` when the source is
    /// already at or below `maxWidth` so callers can skip the work.
    /// Used by `captureRegion` to bound a native-res crop before shipping.
    private static func downscale(_ cgImage: CGImage, maxWidth: CGFloat) -> CGImage? {
        let sourceWidth = CGFloat(cgImage.width)
        guard sourceWidth > maxWidth else { return nil }

        let ratio = maxWidth / sourceWidth
        let newWidth  = Int((sourceWidth * ratio).rounded())
        let newHeight = Int((CGFloat(cgImage.height) * ratio).rounded())
        guard newWidth > 0, newHeight > 0 else { return nil }

        // Use ImageIO's thumbnail path so we get Lanczos-style filtering
        // for free — sharper than a straight CGContext draw at fractional
        // scales, and there's no need for us to manage a bitmap buffer.
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        guard let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(newWidth, newHeight),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Lossless PNG encoder, used for window captures so the shadow's
    /// transparent halo survives the round-trip. JPEG would flatten alpha
    /// to an opaque rectangle and we'd lose the macOS-screenshot look.
    private static func encodePNG(_ cgImage: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CaptureError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
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

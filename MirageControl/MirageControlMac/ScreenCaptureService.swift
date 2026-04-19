//
//  ScreenCaptureService.swift
//  MirageControlMac
//

import AppKit
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

/// Screen-capture pipeline backed by ScreenCaptureKit.
///
/// `CGDisplayCreateImage` is deprecated as of macOS 14 and is removed from the
/// supported surface on macOS 26 (Tahoe); ScreenCaptureKit's `SCScreenshotManager`
/// is the current Apple-recommended path for one-shot screen grabs.
///
/// Permission handling moves from `CGPreflightScreenCaptureAccess` to probing
/// `SCShareableContent` — if the user hasn't granted Screen Recording access the
/// first call surfaces the TCC prompt and throws `.permissionDenied`.
@MainActor
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()
    private init() {}

    enum CaptureError: Error {
        case permissionDenied
        case noDisplay
        case captureFailed(String)
        case encodeFailed
    }

    /// Triggers the system Screen Recording prompt by touching `SCShareableContent`.
    /// Call this once at launch so the dialog appears before the user actually
    /// requests a screenshot from the iPad.
    func primePermission() async {
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Captures the main display and returns JPEG data resized to at most
    /// `maxWidth` points wide.
    func captureMainDisplayJPEG(maxWidth: CGFloat = 1920, quality: CGFloat = 0.75) async throws -> Data {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width  = Int(CGFloat(display.width)  * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }

        return try await Self.resizeAndEncodeJPEG(cgImage, maxWidth: maxWidth, quality: quality)
    }

    private static func resizeAndEncodeJPEG(
        _ cgImage: CGImage,
        maxWidth: CGFloat,
        quality: CGFloat
    ) async throws -> Data {
        let data: Data? = await Task.detached(priority: .userInitiated) {
            let sourceWidth = CGFloat(cgImage.width)
            let sourceHeight = CGFloat(cgImage.height)
            let targetWidth = min(sourceWidth, maxWidth)
            let ratio = targetWidth / sourceWidth
            let targetSize = NSSize(width: targetWidth, height: sourceHeight * ratio)

            let resized = NSImage(size: targetSize)
            resized.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSBitmapImageRep(cgImage: cgImage).draw(in: NSRect(origin: .zero, size: targetSize))
            resized.unlockFocus()

            guard let tiff = resized.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }.value

        guard let data else { throw CaptureError.encodeFailed }
        return data
    }
}

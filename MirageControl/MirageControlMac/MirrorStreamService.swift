//
//  MirrorStreamService.swift
//  MirageControlMac
//
//  Live mini-mirror stream for the iPad control surface (WID-403).
//
//  Pipeline:
//
//    SCStream (GPU-downscaled BGRA, capped fps)
//        → sample-handler queue: CVPixelBuffer → CGImage → JPEG (ImageIO)
//        → MainActor: ControlMessage.mirrorFrame broadcast to subscribers
//
//  Performance / memory invariants:
//
//   • LATEST-FRAME-WINS. While a frame is being encoded or is in flight on
//     the wire, new frames are dropped at the top of the sample handler —
//     nothing is ever queued, so a slow Wi-Fi link degrades to a lower
//     effective frame rate instead of ballooning memory and latency.
//   • The GPU does the downsample inside ScreenCaptureKit (the stream
//     configuration is sized to the *target* output), so we never touch
//     native-resolution pixels on the CPU. A ~480px frame encodes to
//     ~10–30 KB JPEG.
//   • One reusable CIContext; no per-frame context or colorspace churn.
//   • The stream is torn down when the last subscriber leaves, on
//     disconnect, and on stream error — there is no idle capture.
//

import AppKit
import CoreImage
import Foundation
import ImageIO
import LoomKit
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// JPEG quality for mirror frames. File-scope so the off-MainActor encoder
/// can read it without actor hops. 0.5 is the sweet spot for screen
/// content: visibly crisper text than 0.4 for roughly +35% payload, still
/// well inside LAN budgets with latest-frame-wins absorbing congestion.
private let mirrorJPEGQuality: CGFloat = 0.5

@MainActor
final class MirrorStreamService: NSObject {
    static let shared = MirrorStreamService()

    // MARK: - Tunables

    /// Hard caps regardless of what the client asks for, so a buggy or
    /// malicious client can't make the host capture at full resolution
    /// or unbounded rate.
    private static let maxAllowedFPS = 30
    /// Generous enough for the iPad's expanded view at Retina density;
    /// still far below native capture, so encode cost stays trivial.
    private static let maxAllowedWidth = 1280

    // MARK: - State

    private var subscribers: [UUID: LoomConnectionHandle] = [:]
    private var stream: SCStream?
    private var output: MirrorFrameOutput?
    /// Serial queue ScreenCaptureKit delivers frames on. Encoding happens
    /// here too, keeping all pixel work off the main thread.
    private let sampleQueue = DispatchQueue(label: "com.miragecontrol.mirror.frames", qos: .userInteractive)

    private override init() { super.init() }

    // MARK: - Subscriber lifecycle

    /// Adds `handle` as a mirror subscriber, starting the capture stream
    /// if it isn't running. Multiple iPads share one stream; the first
    /// subscriber's fps/width preferences win until the stream restarts.
    func start(subscriberID: UUID, handle: LoomConnectionHandle, fps: Int, maxWidth: Int) async {
        subscribers[subscriberID] = handle
        guard stream == nil else { return }

        let clampedFPS = max(1, min(fps, Self.maxAllowedFPS))
        let clampedWidth = max(120, min(maxWidth, Self.maxAllowedWidth))

        do {
            try await startStream(fps: clampedFPS, maxWidth: clampedWidth)
            MirageLog.app.info("Mirror stream started (\(clampedFPS, privacy: .public) fps, \(clampedWidth, privacy: .public)px)")
        } catch {
            MirageLog.app.error("Mirror stream failed to start: \(error.localizedDescription, privacy: .public)")
            subscribers.removeValue(forKey: subscriberID)
            // Surface the failure through the screenshot error channel the
            // iPad already knows how to present.
            try? await handle.send(.screenshotError(
                requestID: "mirror",
                message: "Live mirror unavailable: \(error.localizedDescription)"
            ))
        }
    }

    /// Removes a subscriber; tears the stream down when none remain.
    /// Safe to call redundantly (disconnect path + explicit stopMirror).
    func stop(subscriberID: UUID) async {
        guard subscribers.removeValue(forKey: subscriberID) != nil else { return }
        if subscribers.isEmpty {
            await teardownStream()
        }
    }

    // MARK: - Stream control

    private func startStream(fps: Int, maxWidth: Int) async throws {
        guard let display = try await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true)
            .displays.first
        else {
            throw ScreenCaptureService.CaptureError.noDisplay
        }

        let aspect = CGFloat(display.height) / CGFloat(display.width)
        let config = SCStreamConfiguration()
        config.width = maxWidth
        config.height = Int((CGFloat(maxWidth) * aspect).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Small queue: stale frames are worthless for a live mirror.
        config.queueDepth = 3
        config.showsCursor = true

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let output = MirrorFrameOutput { [weak self] jpegData, seq in
            // Called on `sampleQueue` after encode. Hop to the MainActor to
            // read the subscriber table and send. `output.busy` stays true
            // until the sends complete — that's the backpressure.
            Task { @MainActor [weak self] in
                await self?.broadcast(jpegData, seq: seq)
                self?.output?.finishFrame()
            }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.stream = stream
        self.output = output
    }

    private func teardownStream() async {
        guard let stream else { return }
        self.stream = nil
        self.output = nil
        try? await stream.stopCapture()
        MirageLog.app.info("Mirror stream stopped")
    }

    /// Called by `MirrorFrameOutput` when ScreenCaptureKit reports the
    /// stream died (display unplugged, TCC revoked mid-stream, …).
    fileprivate func handleStreamFailure(_ error: Error) {
        MirageLog.app.error("Mirror stream error: \(error.localizedDescription, privacy: .public)")
        let handles = Array(subscribers.values)
        subscribers.removeAll()
        stream = nil
        output = nil
        for handle in handles {
            Task {
                try? await handle.send(.screenshotError(
                    requestID: "mirror",
                    message: "Live mirror stopped: \(error.localizedDescription)"
                ))
            }
        }
    }

    private func broadcast(_ data: Data, seq: UInt64) async {
        // Sequential sends: with one subscriber (the normal case) this is
        // exactly the in-flight backpressure we want; with several, the
        // slowest peer paces the shared stream, which keeps total uplink
        // bounded.
        for handle in subscribers.values {
            try? await handle.send(.mirrorFrame(seq: seq, data: data))
        }
    }
}

// MARK: - SCStreamOutput handler

/// Receives frames on the sample-handler queue, encodes, and forwards.
/// `@unchecked Sendable` because all mutable state is confined to the
/// sample-handler queue except `busy`, which is lock-protected (it's
/// cleared from the MainActor when the wire send completes).
private final class MirrorFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called with encoded JPEG + sequence number, on the sample queue.
    private let onFrame: (Data, UInt64) -> Void

    private let lock = NSLock()
    private var busy = false
    private var seq: UInt64 = 0

    /// Reused CIContext — creating one per frame would re-allocate GPU
    /// resources 20× per second.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(onFrame: @escaping (Data, UInt64) -> Void) {
        self.onFrame = onFrame
    }

    /// Clears the in-flight flag once the frame has been shipped.
    func finishFrame() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        // Latest-frame-wins: drop everything while a frame is in flight.
        lock.lock()
        if busy {
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()

        guard let frameData = Self.encode(sampleBuffer, context: ciContext) else {
            finishFrame()
            return
        }

        seq &+= 1
        onFrame(frameData, seq)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            MirrorStreamService.shared.handleStreamFailure(error)
        }
    }

    /// CVPixelBuffer → CGImage → JPEG. Skips incomplete frames (SCK emits
    /// status markers for idle/blank ticks that carry no pixels).
    private static func encode(_ sampleBuffer: CMSampleBuffer, context: CIContext) -> Data? {
        // Only encode frames marked complete.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return nil
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [
            kCGImageDestinationLossyCompressionQuality: mirrorJPEGQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

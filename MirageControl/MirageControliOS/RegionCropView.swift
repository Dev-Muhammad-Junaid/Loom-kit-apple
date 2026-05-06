//
//  RegionCropView.swift
//  MirageControliOS
//
//  Two-step region capture flow:
//
//   1. iPad already has the most recent full-screen capture (the "preview"
//      it just showed in `ScreenshotPreviewView`). User drags out a
//      rectangle on top of that preview.
//   2. On confirm, we ship the *normalized* rect (0…1, origin top-left)
//      back to the Mac, which performs a fresh capture and crops on its
//      side — much sharper than re-scaling the iPad-side JPEG, since the
//      Mac still has access to the native pixel grid.
//
//  This file owns only the cropping UI. The capture round-trip flow lives
//  in `ControlView`, which presents this view modally and receives the
//  resulting `CGRect` (normalized) back through the `onConfirm` callback.
//

import SwiftUI
import UIKit

struct RegionCropView: View {
    /// The full-screen reference image to crop against.
    let image: UIImage
    /// Called with a normalized `CGRect` (0…1, origin top-left). `nil` means
    /// the user cancelled.
    let onConfirm: (CGRect?) -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var startPoint: CGPoint?
    @State private var currentPoint: CGPoint?
    @State private var imageFrame: CGRect = .zero
    @State private var cropRectInImage: CGRect?

    /// Minimum width/height in points before we treat the drag as a real
    /// rectangle. Prevents accidental taps from queuing a degenerate crop.
    private let minimumDragLength: CGFloat = 24

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Reference image fills the screen with letterboxing.
            GeometryReader { geo in
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .background(
                            // Capture the actual on-screen rect of the image
                            // so we can convert touch coords to image coords.
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { imageFrame = imageRectInside(geo.size) }
                                    .onChange(of: geo.size) { _, _ in
                                        imageFrame = imageRectInside(geo.size)
                                    }
                                    .id(proxy.size.width)
                            }
                        )

                    // Dim outside the selected region.
                    if let rect = currentSelectionRect() {
                        DimOutside(selection: rect)
                            .ignoresSafeArea()
                    }

                    // Selection rectangle.
                    if let rect = currentSelectionRect() {
                        Rectangle()
                            .strokeBorder(MirageTheme.violet, lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Clamp drag to the image's on-screen frame so
                            // the user can't draw a rect past the letterbox.
                            let clamped = clampToImage(value.location)
                            if startPoint == nil {
                                startPoint = clampToImage(value.startLocation)
                            }
                            currentPoint = clamped
                        }
                        .onEnded { _ in
                            cropRectInImage = currentSelectionRect()
                                .flatMap(translateToImageSpace)
                        }
                )
            }
            .ignoresSafeArea()

            VStack {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                Spacer()

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Top / bottom chrome

    private var topBar: some View {
        HStack {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onConfirm(nil)
            } label: {
                Text("Cancel")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            Text(headlineText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            Spacer()

            // Reset selection
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                startPoint = nil
                currentPoint = nil
                cropRectInImage = nil
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canConfirm ? Color.white.opacity(0.9) : Color.white.opacity(0.3))
            }
            .disabled(!canConfirm)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                guard let normalized = normalizedSelection() else { return }
                onConfirm(normalized)
            } label: {
                Label("Capture region", systemImage: "rectangle.dashed.badge.record")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(canConfirm ? MirageTheme.violet : Color.gray.opacity(0.5))
                    )
            }
            .disabled(!canConfirm)
            Spacer()
        }
    }

    private var headlineText: String {
        if !canConfirm {
            return "Drag to mark a region"
        }
        return "Tap Capture to grab a fresh shot"
    }

    // MARK: - Geometry

    /// Where the `scaledToFit` image actually lives inside the parent view.
    /// Used so touch coords in screen space convert correctly to image space.
    private func imageRectInside(_ container: CGSize) -> CGRect {
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0 else { return .zero }
        let scale = min(container.width / imgW, container.height / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let x = (container.width - drawW) / 2
        let y = (container.height - drawH) / 2
        return CGRect(x: x, y: y, width: drawW, height: drawH)
    }

    private func clampToImage(_ point: CGPoint) -> CGPoint {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return point }
        return CGPoint(
            x: min(max(point.x, imageFrame.minX), imageFrame.maxX),
            y: min(max(point.y, imageFrame.minY), imageFrame.maxY)
        )
    }

    private func currentSelectionRect() -> CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        let rect = CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
        return rect
    }

    private func translateToImageSpace(_ rectOnScreen: CGRect) -> CGRect? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let dx = rectOnScreen.minX - imageFrame.minX
        let dy = rectOnScreen.minY - imageFrame.minY
        return CGRect(x: dx, y: dy, width: rectOnScreen.width, height: rectOnScreen.height)
    }

    /// Final 0…1 normalized rect in image space, ready to ship to the Mac.
    /// `nil` if the drag is too small or hasn't happened yet.
    private func normalizedSelection() -> CGRect? {
        guard let onScreen = currentSelectionRect(),
              onScreen.width >= minimumDragLength,
              onScreen.height >= minimumDragLength,
              let inImage = translateToImageSpace(onScreen)
        else { return nil }
        let w = imageFrame.width
        let h = imageFrame.height
        return CGRect(
            x: max(0, inImage.minX / w),
            y: max(0, inImage.minY / h),
            width: min(1.0, inImage.width / w),
            height: min(1.0, inImage.height / h)
        )
    }

    private var canConfirm: Bool {
        normalizedSelection() != nil
    }
}

// MARK: - Dim outside

/// Black-out the area outside `selection` so the user has clear sense of
/// what's being captured. Uses a single `Path` with even-odd fill so we
/// don't have to manage four sub-rects.
private struct DimOutside: View {
    let selection: CGRect

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: geo.size))
                path.addRect(selection)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
        }
    }
}

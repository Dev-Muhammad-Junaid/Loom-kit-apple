//
//  RegionCropView.swift
//  DeckHandiOS
//
//  Two-step region capture flow:
//
//   1. iPad already has the most recent full-screen capture (the "preview"
//      it just showed in `ScreenshotPreviewView`). User drags out a
//      rectangle on top of that preview, then refines it freely:
//         • Drag inside the rect to move it.
//         • Drag any of 8 handles (4 corners + 4 edge midpoints) to resize.
//         • Drag outside the rect to start a fresh selection.
//   2. On confirm, we ship the *normalized* rect (0…1, origin top-left)
//      back to the Mac, which performs a fresh capture and crops on its
//      side — much sharper than re-scaling the iPad-side JPEG, since the
//      Mac still has access to the native pixel grid.
//
//  Visual: white outline + white square handles (with a 1pt black inner
//  stroke for visibility on light backgrounds). Brand violet only appears
//  on the "Capture region" affordance.
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

    /// Current rectangle, in screen-space coordinates relative to the
    /// view's coordinate space. `nil` means "no selection yet" — the next
    /// drag will lay one down.
    @State private var selection: CGRect?
    /// What kind of drag we're currently servicing. Decided at the *first*
    /// onChanged tick of a gesture and stays fixed until onEnded.
    @State private var dragKind: DragKind = .none
    /// Snapshot of `selection` at gesture start (for moves and resizes
    /// where we need to know the original frame the drag is editing).
    @State private var dragStartSelection: CGRect?
    @State private var dragStartLocation: CGPoint?
    /// On-screen frame of the underlying `Image`, captured via the
    /// transparent GeometryReader. We map between screen / image space
    /// using this.
    @State private var imageFrame: CGRect = .zero

    /// Minimum drag length before we treat a fresh-draw gesture as a real
    /// rectangle. Prevents accidental taps from queuing degenerate crops.
    private let minimumDragLength: CGFloat = 24
    private let handleVisualSize: CGFloat = 14
    /// Inflated touch target for handles. The white square is 14pt but we
    /// still want it finger-friendly.
    private let handleHitInset: CGFloat = -22
    /// Minimum size the user can shrink the rect to during a resize, so
    /// they can't accidentally squish it into a degenerate strip and have
    /// to start over.
    private let minimumRectSide: CGFloat = 32

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .background(
                            GeometryReader { _ in
                                Color.clear
                                    .onAppear { imageFrame = imageRectInside(geo.size) }
                                    .onChange(of: geo.size) { _, _ in
                                        imageFrame = imageRectInside(geo.size)
                                    }
                            }
                        )

                    // Dim everything outside the current selection.
                    if let rect = selection {
                        DimOutside(selection: rect)
                            .ignoresSafeArea()
                    }

                    // Selection rectangle.
                    if let rect = selection {
                        Rectangle()
                            .strokeBorder(Color.white, lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                            .shadow(color: .black.opacity(0.45), radius: 1)

                        // Handles: 4 corners + 4 edge midpoints.
                        ForEach(Handle.allCases, id: \.self) { handle in
                            HandleSquare(size: handleVisualSize)
                                .position(handle.position(in: rect))
                                .allowsHitTesting(false)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleDragChange(value)
                        }
                        .onEnded { _ in
                            dragKind = .none
                            dragStartSelection = nil
                            dragStartLocation = nil
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
                selection = nil
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
                        Capsule().fill(canConfirm ? DeckHandTheme.violet : Color.gray.opacity(0.5))
                    )
            }
            .disabled(!canConfirm)
            Spacer()
        }
    }

    private var headlineText: String {
        if selection == nil {
            return "Drag to mark a region"
        }
        if !canConfirm {
            return "Drag a corner or edge to resize"
        }
        return "Drag to move · Corners to resize"
    }

    // MARK: - Drag dispatch

    private func handleDragChange(_ value: DragGesture.Value) {
        // First tick of a gesture decides what kind it is and stashes the
        // original rect so we can compute deltas without drift.
        if dragKind == .none {
            dragStartLocation = value.startLocation
            dragStartSelection = selection
            dragKind = classifyDrag(start: clampToImage(value.startLocation),
                                    rect: selection)
        }

        let current = clampToImage(value.location)
        switch dragKind {
        case .none:
            break

        case .drawing:
            guard let start = dragStartLocation else { return }
            let clampedStart = clampToImage(start)
            selection = CGRect(
                x: min(clampedStart.x, current.x),
                y: min(clampedStart.y, current.y),
                width: abs(current.x - clampedStart.x),
                height: abs(current.y - clampedStart.y)
            )

        case .moving:
            guard let original = dragStartSelection,
                  let start = dragStartLocation else { return }
            let dx = current.x - start.x
            let dy = current.y - start.y
            var moved = original.offsetBy(dx: dx, dy: dy)
            // Clamp the rect inside the image bounds, preserving size.
            if moved.minX < imageFrame.minX { moved.origin.x = imageFrame.minX }
            if moved.minY < imageFrame.minY { moved.origin.y = imageFrame.minY }
            if moved.maxX > imageFrame.maxX {
                moved.origin.x = imageFrame.maxX - moved.width
            }
            if moved.maxY > imageFrame.maxY {
                moved.origin.y = imageFrame.maxY - moved.height
            }
            selection = moved

        case let .resizing(handle):
            guard let original = dragStartSelection else { return }
            selection = resize(original, with: handle, toward: current)
        }
    }

    private func classifyDrag(start: CGPoint, rect: CGRect?) -> DragKind {
        guard let rect else { return .drawing }

        // Handle hits first (with the inflated touch target so corners
        // are easy to grab).
        for handle in Handle.allCases {
            let handleRect = CGRect(origin: handle.position(in: rect), size: .zero)
                .insetBy(dx: handleHitInset, dy: handleHitInset)
            if handleRect.contains(start) {
                return .resizing(handle)
            }
        }

        // Inside the existing rect (but missing a handle) → move.
        if rect.contains(start) {
            return .moving
        }

        // Otherwise the user has tapped outside their previous rect, so
        // re-use the existing "fresh draw" path. Wipe the old selection
        // so the geometry math during this drag matches the drawing case.
        selection = nil
        return .drawing
    }

    private func resize(_ original: CGRect, with handle: Handle, toward point: CGPoint) -> CGRect {
        // Each handle pins the *opposite* corner / edge — mirroring how
        // macOS's window resize works. Corner handles drag both axes;
        // midpoints constrain to one axis.
        var minX = original.minX
        var minY = original.minY
        var maxX = original.maxX
        var maxY = original.maxY

        switch handle {
        case .topLeft:
            minX = min(point.x, maxX - minimumRectSide)
            minY = min(point.y, maxY - minimumRectSide)
        case .topRight:
            maxX = max(point.x, minX + minimumRectSide)
            minY = min(point.y, maxY - minimumRectSide)
        case .bottomLeft:
            minX = min(point.x, maxX - minimumRectSide)
            maxY = max(point.y, minY + minimumRectSide)
        case .bottomRight:
            maxX = max(point.x, minX + minimumRectSide)
            maxY = max(point.y, minY + minimumRectSide)
        case .top:
            minY = min(point.y, maxY - minimumRectSide)
        case .bottom:
            maxY = max(point.y, minY + minimumRectSide)
        case .left:
            minX = min(point.x, maxX - minimumRectSide)
        case .right:
            maxX = max(point.x, minX + minimumRectSide)
        }

        // Clamp to image bounds.
        minX = max(minX, imageFrame.minX)
        minY = max(minY, imageFrame.minY)
        maxX = min(maxX, imageFrame.maxX)
        maxY = min(maxY, imageFrame.maxY)

        return CGRect(x: minX, y: minY,
                      width: max(0, maxX - minX),
                      height: max(0, maxY - minY))
    }

    // MARK: - Geometry helpers

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

    private func translateToImageSpace(_ rectOnScreen: CGRect) -> CGRect? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let dx = rectOnScreen.minX - imageFrame.minX
        let dy = rectOnScreen.minY - imageFrame.minY
        return CGRect(x: dx, y: dy, width: rectOnScreen.width, height: rectOnScreen.height)
    }

    /// Final 0…1 normalized rect in image space, ready to ship to the Mac.
    /// `nil` if the rect is too small or doesn't exist yet.
    private func normalizedSelection() -> CGRect? {
        guard let onScreen = selection,
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

// MARK: - Drag classification

private enum DragKind: Equatable {
    case none
    /// Fresh rect being drawn.
    case drawing
    /// Existing rect being translated.
    case moving
    /// Existing rect being resized via a particular handle.
    case resizing(Handle)
}

private enum Handle: CaseIterable, Hashable {
    case topLeft, top, topRight
    case left,           right
    case bottomLeft, bottom, bottomRight

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

// MARK: - Subviews

/// White square handle with a thin black inner stroke so it stays visible
/// on both light and dark image content.
private struct HandleSquare: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.5), radius: 1.5)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(Color.black.opacity(0.45), lineWidth: 1)
                .frame(width: size, height: size)
        }
    }
}

/// Black-out the area outside `selection` so the user has clear sense of
/// what's being captured. Single `Path` with even-odd fill so we don't have
/// to manage four sub-rects.
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

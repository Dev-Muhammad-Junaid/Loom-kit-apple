//
//  AnnotationView.swift
//  MirageControliOS
//

import SwiftUI
import UIKit

// MARK: - Stroke Model

private struct Stroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var color: UIColor
    var width: CGFloat
}

// MARK: - AnnotationView

struct AnnotationView: View {
    /// The base screenshot to annotate.
    let image: UIImage
    /// Called with the composited (image + drawing) UIImage, or `nil` if cancelled.
    let onFinish: (UIImage?) -> Void

    // Drawing state
    @State private var strokes: [Stroke] = []
    @State private var currentStroke: Stroke?

    // Tool state
    @State private var selectedColor: UIColor = .systemRed
    @State private var strokeWidth: CGFloat = 4

    // Canvas size — captured by GeometryReader so we can export at the right scale
    @State private var canvasSize: CGSize = .zero

    // Palette options
    private let palette: [UIColor] = [
        .systemRed, .systemOrange, .systemYellow,
        .systemGreen, .systemCyan, .systemBlue,
        .systemPurple, .white, .black
    ]

    // Width presets
    private let widths: [CGFloat] = [2, 4, 8, 14]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ── Base image ───────────────────────────────────────────────
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
            }
            .ignoresSafeArea()

            // ── Drawing canvas ───────────────────────────────────────────
            Canvas { ctx, size in
                // Already-finished strokes
                for stroke in strokes {
                    drawStroke(stroke, in: &ctx)
                }
                // Live stroke
                if let live = currentStroke {
                    drawStroke(live, in: &ctx)
                }
            }
            .ignoresSafeArea()
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if currentStroke == nil {
                            currentStroke = Stroke(points: [], color: selectedColor, width: strokeWidth)
                        }
                        currentStroke?.points.append(value.location)
                    }
                    .onEnded { _ in
                        if let finished = currentStroke {
                            strokes.append(finished)
                        }
                        currentStroke = nil
                    }
            )

            // ── UI Chrome ────────────────────────────────────────────────
            VStack {
                // Top bar
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                Spacer()

                // Bottom toolbar
                bottomToolbar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button("Cancel") {
                onFinish(nil)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))

            Spacer()

            Text("Annotate")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Button("Done") {
                onFinish(exportAnnotatedImage())
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        VStack(spacing: 14) {
            // Stroke width pills
            HStack(spacing: 10) {
                ForEach(widths, id: \.self) { w in
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                            strokeWidth = w
                        }
                    } label: {
                        Circle()
                            .fill(Color(uiColor: selectedColor))
                            .frame(width: w * 2.2 + 6, height: w * 2.2 + 6)
                            .overlay(
                                Circle()
                                    .strokeBorder(.white.opacity(strokeWidth == w ? 0.9 : 0.25),
                                                  lineWidth: strokeWidth == w ? 2 : 1)
                            )
                            .scaleEffect(strokeWidth == w ? 1.15 : 1.0)
                            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: strokeWidth)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Undo button
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if !strokes.isEmpty { strokes.removeLast() }
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white.opacity(strokes.isEmpty ? 0.3 : 0.85))
                }
                .buttonStyle(.plain)
                .disabled(strokes.isEmpty)
                .animation(.easeInOut(duration: 0.15), value: strokes.isEmpty)

                // Clear button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation { strokes.removeAll() }
                } label: {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white.opacity(strokes.isEmpty ? 0.3 : 0.7))
                }
                .buttonStyle(.plain)
                .disabled(strokes.isEmpty)
                .animation(.easeInOut(duration: 0.15), value: strokes.isEmpty)
            }

            // Color palette
            HStack(spacing: 10) {
                ForEach(palette, id: \.self) { color in
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                            selectedColor = color
                        }
                    } label: {
                        Circle()
                            .fill(Color(uiColor: color))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        selectedColor == color ? .white : .white.opacity(0.25),
                                        lineWidth: selectedColor == color ? 2.5 : 1
                                    )
                            )
                            .scaleEffect(selectedColor == color ? 1.2 : 1.0)
                            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: selectedColor == color)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Drawing Helper

    private func drawStroke(_ stroke: Stroke, in ctx: inout GraphicsContext) {
        guard stroke.points.count > 1 else {
            // Single tap — draw a dot
            if let pt = stroke.points.first {
                var dot = ctx
                dot.fill(
                    Path(ellipseIn: CGRect(x: pt.x - stroke.width / 2,
                                           y: pt.y - stroke.width / 2,
                                           width: stroke.width,
                                           height: stroke.width)),
                    with: .color(Color(uiColor: stroke.color))
                )
            }
            return
        }

        var path = Path()
        path.move(to: stroke.points[0])
        for i in 1 ..< stroke.points.count {
            // Smooth with quadratic curve
            let prev = stroke.points[i - 1]
            let curr = stroke.points[i]
            let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        path.addLine(to: stroke.points.last!)

        var copy = ctx
        copy.stroke(
            path,
            with: .color(Color(uiColor: stroke.color)),
            style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Export

    /// Composites the strokes on top of the original image and returns a new UIImage.
    private func exportAnnotatedImage() -> UIImage {
        let size = canvasSize
        guard size != .zero else { return image }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            // Draw the base image scaled to fit the canvas
            let imgSize = image.size
            let scale = min(size.width / imgSize.width, size.height / imgSize.height)
            let drawW = imgSize.width * scale
            let drawH = imgSize.height * scale
            let drawX = (size.width - drawW) / 2
            let drawY = (size.height - drawH) / 2
            image.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

            // Replay all strokes using UIKit
            for stroke in strokes {
                guard !stroke.points.isEmpty else { continue }
                stroke.color.setStroke()
                let path = UIBezierPath()
                path.lineWidth = stroke.width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round

                if stroke.points.count == 1 {
                    let pt = stroke.points[0]
                    let r = stroke.width / 2
                    UIBezierPath(ovalIn: CGRect(x: pt.x - r, y: pt.y - r,
                                               width: stroke.width, height: stroke.width)).fill()
                } else {
                    path.move(to: stroke.points[0])
                    for i in 1 ..< stroke.points.count {
                        let prev = stroke.points[i - 1]
                        let curr = stroke.points[i]
                        let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
                        path.addQuadCurve(to: mid, controlPoint: prev)
                    }
                    path.addLine(to: stroke.points.last!)
                    path.stroke()
                }
            }
        }
    }
}

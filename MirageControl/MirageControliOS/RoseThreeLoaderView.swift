//
//  RoseThreeLoaderView.swift
//  MirageControliOS
//
//  “Rose Three” parametric loader (r = a cos(3θ) family), matching the reference
//  math-curve-loader behavior: breathing detail scale, particle trail, faint path, rotation.
//

import SwiftUI

// MARK: - Public view

struct RoseThreeLoaderView: View {
    /// ViewBox is 0…100; this is the drawn square size in points.
    var size: CGFloat = 72
    var color: Color = .primary

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let timeMs = context.date.timeIntervalSince1970 * 1000
            Canvas { canvasContext, canvasSize in
                RoseThreeRenderer.draw(
                    context: &canvasContext,
                    canvasSize: canvasSize,
                    timeMs: timeMs,
                    color: color
                )
            }
            .frame(width: size, height: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MirageControl")
    }
}

// MARK: - Renderer (ported from reference JS)

private enum RoseThreeRenderer {

    private static let particleCount = 101
    private static let trailSpan = 0.31
    private static let durationMs = 5300.0
    private static let rotationDurationMs = 28000.0
    private static let pulseDurationMs = 4400.0
    private static let strokeWidth = 4.6
    private static let roseA = 9.2
    private static let roseABoost = 0.6
    private static let roseBreathBase = 0.72
    private static let roseBreathBoost = 0.28
    private static let roseScale = 3.25
    private static let pathSteps = 480

    static func draw(context: inout GraphicsContext, canvasSize: CGSize, timeMs: Double, color: Color) {
        let scale = min(canvasSize.width, canvasSize.height) / 100
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let rotationRad = rotationRadians(timeMs: timeMs)
        let detailScale = detailScale(timeMs: timeMs)
        let progress = timeMod(timeMs, durationMs) / durationMs

        // Faint full curve (same transform as particles)
        let guidePath = buildScreenPath(
            detailScale: detailScale,
            center: center,
            scale: scale,
            rotationRad: rotationRad
        )
        context.stroke(
            guidePath,
            with: .color(color.opacity(0.1)),
            style: StrokeStyle(lineWidth: strokeWidth * scale, lineCap: .round, lineJoin: .round)
        )

        // Particles along the trail
        let maxIndex = particleCount - 1
        for index in 0..<particleCount {
            let tailOffset = Double(index) / Double(maxIndex)
            let pProgress = normalizeProgress(progress - tailOffset * trailSpan)
            let p = point(progress: pProgress, detailScale: detailScale)
            let screen = mapPoint(p, center: center, scale: scale, rotationRad: rotationRad)
            let fade = pow(1 - tailOffset, 0.56)
            let radius = (0.9 + fade * 2.7) * scale
            let opacity = 0.04 + fade * 0.96
            let rect = CGRect(x: screen.x - radius, y: screen.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
        }
    }

    // MARK: - Math (matches reference)

    private static func point(progress: Double, detailScale: Double) -> CGPoint {
        let t = progress * Double.pi * 2
        let a = roseA + detailScale * roseABoost
        let r = a * (roseBreathBase + detailScale * roseBreathBoost) * cos(3 * t)
        let x = 50 + cos(t) * r * roseScale
        let y = 50 + sin(t) * r * roseScale
        return CGPoint(x: x, y: y)
    }

    private static func normalizeProgress(_ progress: Double) -> Double {
        var p = progress.truncatingRemainder(dividingBy: 1)
        if p < 0 { p += 1 }
        return p
    }

    private static func detailScale(timeMs: Double) -> Double {
        let pulseProgress = timeMod(timeMs, pulseDurationMs) / pulseDurationMs
        let pulseAngle = pulseProgress * Double.pi * 2
        return 0.52 + ((sin(pulseAngle + 0.55) + 1) / 2) * 0.48
    }

    private static func rotationRadians(timeMs: Double) -> Double {
        let t = timeMod(timeMs, rotationDurationMs) / rotationDurationMs
        let degrees = -t * 360
        return degrees * Double.pi / 180
    }

    private static func timeMod(_ t: Double, _ m: Double) -> Double {
        var r = t.truncatingRemainder(dividingBy: m)
        if r < 0 { r += m }
        return r
    }

    private static func buildScreenPath(
        detailScale: Double,
        center: CGPoint,
        scale: CGFloat,
        rotationRad: Double
    ) -> Path {
        var path = Path()
        for index in 0...pathSteps {
            let p = point(progress: Double(index) / Double(pathSteps), detailScale: detailScale)
            let sp = mapPoint(p, center: center, scale: scale, rotationRad: rotationRad)
            if index == 0 {
                path.move(to: sp)
            } else {
                path.addLine(to: sp)
            }
        }
        return path
    }

    private static func mapPoint(_ p: CGPoint, center: CGPoint, scale: CGFloat, rotationRad: Double) -> CGPoint {
        let x = p.x - 50
        let y = p.y - 50
        let c = cos(rotationRad)
        let s = sin(rotationRad)
        let rx = x * c - y * s
        let ry = x * s + y * c
        return CGPoint(x: center.x + CGFloat(rx) * scale, y: center.y + CGFloat(ry) * scale)
    }
}

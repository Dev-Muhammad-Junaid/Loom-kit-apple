//
//  CursorLocator.swift
//  DeckHandMac
//
//  Floating overlay that pulses a multi-color target ring at the live
//  cursor position so a user looking at the iPad can spot where the Mac
//  cursor is. Triggered by the iPad's "Locate" gesture button.
//
//  Visual design — built to survive any wallpaper:
//    • Outer pulse — violet, expanding + fading. White stroke under it for
//      contrast on light backgrounds.
//    • Solid main ring — thick violet stroke (6pt) with a tighter white
//      halo just outside (2pt). Reads as a "target" silhouette.
//    • Inner ring — yellow (3pt). Yellow + violet is a high-contrast pair
//      that stays visible on both light and dark surfaces.
//    • Crosshair — 4pt violet arms with a 1.5pt white stroke under, leaving
//      a 22pt clear zone in the middle so the actual cursor stays visible.
//
//  Implementation notes:
//    • Uses a borderless `NSPanel` per ping — repositioned to whichever
//      display the cursor currently lives on so multi-monitor setups
//      always show the indicator on the right screen.
//    • The panel is `ignoresMouseEvents = true` and `level = .statusBar`
//      so it floats above everything (including full-screen apps) without
//      stealing input.
//    • The animation is a 1.5 s sequence built from `CABasicAnimation` /
//      `CAKeyframeAnimation` — no AppKit view animation system needed.
//

import AppKit
import Foundation
import QuartzCore

@MainActor
final class CursorLocator {
    static let shared = CursorLocator()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// Outer dimension of the indicator window. Kept generous so the
    /// thicker strokes + outer pulse have room to render.
    private let indicatorEdge: CGFloat = 260

    private init() {}

    /// Briefly highlights the cursor's current position. Idempotent: a
    /// second call within the active window cancels the pending dismiss
    /// and restarts the animation, which is what users expect when they
    /// double-tap the locate button.
    func ping() {
        dismissTask?.cancel()

        let indicatorSize = NSSize(width: indicatorEdge, height: indicatorEdge)
        let cursorScreenPoint = NSEvent.mouseLocation
        let origin = NSPoint(
            x: cursorScreenPoint.x - indicatorSize.width / 2,
            y: cursorScreenPoint.y - indicatorSize.height / 2
        )
        let frame = NSRect(origin: origin, size: indicatorSize)

        let panel = panel ?? makePanel(size: indicatorSize)
        self.panel = panel
        panel.setFrame(frame, display: false)

        // Recreate the indicator view so the animation restarts cleanly.
        let view = LocatorIndicatorView(frame: NSRect(origin: .zero, size: indicatorSize))
        panel.contentView = view
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()
        view.startAnimation()

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self.fadeOutAndHide()
        }
    }

    private func fadeOutAndHide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

// MARK: - Indicator view

private final class LocatorIndicatorView: NSView {
    private let outerPulseHalo  = CAShapeLayer()   // white halo under outer pulse
    private let outerPulse      = CAShapeLayer()   // violet outer pulse
    private let mainRingHalo    = CAShapeLayer()   // white halo around main ring
    private let mainRing        = CAShapeLayer()   // violet main ring
    private let innerRing       = CAShapeLayer()   // yellow target ring
    private let crossHalo       = CAShapeLayer()   // white halo under crosshair
    private let crossLayer      = CAShapeLayer()   // violet crosshair

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var violet: NSColor {
        NSColor(red: 0x6C / 255.0, green: 0x63 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    }
    private var yellow: NSColor {
        NSColor(red: 0xFA / 255.0, green: 0xCC / 255.0, blue: 0x15 / 255.0, alpha: 1.0)
    }
    private var halo: NSColor {
        // Slightly softened white so the halos don't clip on light walls.
        NSColor(white: 1.0, alpha: 0.95)
    }

    private func configureLayers() {
        guard let layer else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // ── Main ring (target silhouette) ────────────────────────────────
        let mainRadius: CGFloat = 42
        let mainPath = CGPath(
            ellipseIn: CGRect(
                x: center.x - mainRadius,
                y: center.y - mainRadius,
                width: mainRadius * 2,
                height: mainRadius * 2
            ),
            transform: nil
        )

        mainRingHalo.frame = bounds
        mainRingHalo.path = mainPath
        mainRingHalo.fillColor = NSColor.clear.cgColor
        mainRingHalo.strokeColor = halo.cgColor
        mainRingHalo.lineWidth = 9
        mainRingHalo.opacity = 0
        layer.addSublayer(mainRingHalo)

        mainRing.frame = bounds
        mainRing.path = mainPath
        mainRing.fillColor = NSColor.clear.cgColor
        mainRing.strokeColor = violet.cgColor
        mainRing.lineWidth = 6
        mainRing.opacity = 0
        layer.addSublayer(mainRing)

        // ── Inner yellow ring ────────────────────────────────────────────
        let innerRadius: CGFloat = 28
        let innerPath = CGPath(
            ellipseIn: CGRect(
                x: center.x - innerRadius,
                y: center.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            ),
            transform: nil
        )
        innerRing.frame = bounds
        innerRing.path = innerPath
        innerRing.fillColor = NSColor.clear.cgColor
        innerRing.strokeColor = yellow.cgColor
        innerRing.lineWidth = 3
        innerRing.opacity = 0
        layer.addSublayer(innerRing)

        // ── Outer pulse ──────────────────────────────────────────────────
        let pulsePath = mainPath
        outerPulseHalo.frame = bounds
        outerPulseHalo.path = pulsePath
        outerPulseHalo.fillColor = NSColor.clear.cgColor
        outerPulseHalo.strokeColor = halo.cgColor
        outerPulseHalo.lineWidth = 9
        outerPulseHalo.opacity = 0
        layer.addSublayer(outerPulseHalo)

        outerPulse.frame = bounds
        outerPulse.path = pulsePath
        outerPulse.fillColor = NSColor.clear.cgColor
        outerPulse.strokeColor = violet.withAlphaComponent(0.85).cgColor
        outerPulse.lineWidth = 7
        outerPulse.opacity = 0
        layer.addSublayer(outerPulse)

        // ── Crosshair (with halo for contrast) ───────────────────────────
        let armOuter: CGFloat = 78
        let armInner: CGFloat = 22
        let crossPath = CGMutablePath()
        crossPath.move(to: CGPoint(x: center.x - armOuter, y: center.y))
        crossPath.addLine(to: CGPoint(x: center.x - armInner, y: center.y))
        crossPath.move(to: CGPoint(x: center.x + armInner, y: center.y))
        crossPath.addLine(to: CGPoint(x: center.x + armOuter, y: center.y))
        crossPath.move(to: CGPoint(x: center.x, y: center.y - armOuter))
        crossPath.addLine(to: CGPoint(x: center.x, y: center.y - armInner))
        crossPath.move(to: CGPoint(x: center.x, y: center.y + armInner))
        crossPath.addLine(to: CGPoint(x: center.x, y: center.y + armOuter))

        crossHalo.frame = bounds
        crossHalo.path = crossPath
        crossHalo.strokeColor = halo.cgColor
        crossHalo.lineWidth = 7
        crossHalo.lineCap = .round
        crossHalo.opacity = 0
        layer.addSublayer(crossHalo)

        crossLayer.frame = bounds
        crossLayer.path = crossPath
        crossLayer.strokeColor = violet.cgColor
        crossLayer.lineWidth = 4
        crossLayer.lineCap = .round
        crossLayer.opacity = 0
        layer.addSublayer(crossLayer)
    }

    func startAnimation() {
        // Static elements fade in.
        let staticLayers: [CALayer] = [
            mainRingHalo, mainRing, innerRing, crossHalo, crossLayer,
        ]
        for l in staticLayers {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            l.add(fade, forKey: "fadeIn")
        }

        // Inner yellow ring gets a small "attention beat" scale pulse so
        // it punctuates the violet outer ring.
        let innerPulse = CABasicAnimation(keyPath: "transform.scale")
        innerPulse.fromValue = 0.85
        innerPulse.toValue = 1.0
        innerPulse.duration = 0.32
        innerPulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        innerRing.add(innerPulse, forKey: "innerPulse")

        // Outer pulse: opacity ramps in then out, scale grows. We animate
        // halo + violet stroke as a group so they expand together.
        let pulseDuration: CFTimeInterval = 0.95
        for (index, l) in [outerPulseHalo, outerPulse].enumerated() {
            let group = CAAnimationGroup()
            group.duration = pulseDuration
            group.repeatCount = 1.0

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            // Halo is a touch dimmer than the violet so it reads as a
            // contrasting underline rather than competing for the eye.
            let peak = (index == 0) ? 0.55 : 0.85
            fade.values = [0.0, peak, 0.0]
            fade.keyTimes = [0.0, 0.4, 1.0]

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.6
            scale.toValue = 1.7
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

            group.animations = [fade, scale]
            l.add(group, forKey: "pulse")
        }
    }
}

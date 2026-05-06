//
//  CursorLocator.swift
//  MirageControlMac
//
//  Floating overlay that pulses a violet ring + crosshair at the live
//  cursor position so a user looking at the iPad can spot where the Mac
//  cursor is. Triggered by the iPad's "Locate" gesture button.
//
//  Implementation notes:
//   • Uses a borderless `NSPanel` per display so multi-monitor setups
//     show the indicator on whichever screen the cursor is currently on.
//   • The panel is `ignoresMouseEvents = true` and `level = .statusBar`
//     so it floats above everything (including full-screen apps) without
//     stealing input.
//   • The animation is a 1.5 s sequence that doesn't require pulling in
//     AppKit's view animation system — `NSAnimationContext` with explicit
//     keyframes keeps the implementation small and deterministic.
//

import AppKit
import Foundation
import QuartzCore

@MainActor
final class CursorLocator {
    static let shared = CursorLocator()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Briefly highlights the cursor's current position. Idempotent: a
    /// second call within the active window cancels the pending dismiss
    /// and restarts the animation, which is what users expect when they
    /// double-tap the locate button.
    func ping() {
        dismissTask?.cancel()

        let indicatorSize = NSSize(width: 220, height: 220)
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
    private let ringLayer = CAShapeLayer()
    private let pulseLayer = CAShapeLayer()
    private let crossLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var brandColor: NSColor {
        // Violet matches the iPad client's brand accent.
        NSColor(red: 0x6C / 255.0, green: 0x63 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    }

    private func configureLayers() {
        guard let layer else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let ringRadius: CGFloat = 36

        // Solid ring around the cursor.
        ringLayer.frame = bounds
        ringLayer.path = CGPath(
            ellipseIn: CGRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            ),
            transform: nil
        )
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = brandColor.cgColor
        ringLayer.lineWidth = 3
        ringLayer.opacity = 0
        layer.addSublayer(ringLayer)

        // Outer pulse that fades + grows.
        pulseLayer.frame = bounds
        pulseLayer.path = ringLayer.path
        pulseLayer.fillColor = NSColor.clear.cgColor
        pulseLayer.strokeColor = brandColor.withAlphaComponent(0.6).cgColor
        pulseLayer.lineWidth = 5
        pulseLayer.opacity = 0
        layer.addSublayer(pulseLayer)

        // Crosshair lines that point in to the cursor.
        let armLength: CGFloat = 70
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - armLength, y: center.y))
        path.addLine(to: CGPoint(x: center.x - 22, y: center.y))
        path.move(to: CGPoint(x: center.x + 22, y: center.y))
        path.addLine(to: CGPoint(x: center.x + armLength, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - armLength))
        path.addLine(to: CGPoint(x: center.x, y: center.y - 22))
        path.move(to: CGPoint(x: center.x, y: center.y + 22))
        path.addLine(to: CGPoint(x: center.x, y: center.y + armLength))
        crossLayer.frame = bounds
        crossLayer.path = path
        crossLayer.strokeColor = brandColor.cgColor
        crossLayer.lineWidth = 2
        crossLayer.lineCap = .round
        crossLayer.opacity = 0
        layer.addSublayer(crossLayer)
    }

    func startAnimation() {
        // Ring fade-in
        let ringIn = CABasicAnimation(keyPath: "opacity")
        ringIn.fromValue = 0
        ringIn.toValue = 1
        ringIn.duration = 0.18
        ringIn.fillMode = .forwards
        ringIn.isRemovedOnCompletion = false
        ringLayer.add(ringIn, forKey: "ringIn")

        let crossIn = CABasicAnimation(keyPath: "opacity")
        crossIn.fromValue = 0
        crossIn.toValue = 1
        crossIn.duration = 0.18
        crossIn.fillMode = .forwards
        crossIn.isRemovedOnCompletion = false
        crossLayer.add(crossIn, forKey: "crossIn")

        // Pulse: opacity in then out, scale up.
        let pulseGroup = CAAnimationGroup()
        pulseGroup.duration = 0.9
        pulseGroup.repeatCount = 1.0

        let pulseFade = CAKeyframeAnimation(keyPath: "opacity")
        pulseFade.values = [0.0, 0.85, 0.0]
        pulseFade.keyTimes = [0.0, 0.4, 1.0]

        let pulseScale = CABasicAnimation(keyPath: "transform.scale")
        pulseScale.fromValue = 0.6
        pulseScale.toValue = 1.7
        pulseScale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        pulseGroup.animations = [pulseFade, pulseScale]
        pulseLayer.add(pulseGroup, forKey: "pulse")
    }
}

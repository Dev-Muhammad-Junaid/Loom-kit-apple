//
//  ScrollPhase.swift
//  MirageControl – Shared
//
//  Shared phase tag for `mouseScroll` so AppKit / WebKit can run their
//  native rubber-banding + momentum animations. Without these phases the
//  Mac sees a stream of un-phased wheel ticks, which look mouse-wheel-y
//  rather than trackpad-y.
//
//  The vocabulary mirrors `NSEvent.Phase` / `NSEvent.MomentumPhase` but
//  doesn't drag in AppKit so the iPad target can use it too.
//

import Foundation

public enum ScrollPhase: String, Codable, Sendable, Hashable {
    /// Finger landed; first delta of a scroll gesture.
    case begin
    /// Continuous scroll deltas while the finger is on-glass.
    case changed
    /// Finger lifted with no momentum (slow drag, lazy stop).
    case end
    /// Finger lifted with momentum; physics-driven decay begins.
    case momentumBegin
    /// Continued physics-driven deltas during momentum decay.
    case momentumChanged
    /// Momentum decay finished; gesture is fully done.
    case momentumEnd
}

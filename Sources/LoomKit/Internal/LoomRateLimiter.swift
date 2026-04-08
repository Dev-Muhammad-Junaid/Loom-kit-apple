//
//  LoomRateLimiter.swift
//  LoomKit
//
//  Token-bucket rate limiter for incoming message streams.
//

import Foundation

/// Configures rate limiting for incoming messages on the default message stream.
///
/// Uses a token-bucket algorithm: tokens refill at a steady rate up to a
/// maximum burst size. Each message consumes one token. When the bucket is
/// empty, excess messages are dropped and logged.
///
/// The default policy is ``unlimited`` — no messages are dropped. Use one of
/// the built-in presets or create a custom policy if your app needs to protect
/// against flood scenarios:
///
/// ```swift
/// // Real-time apps (trackpad, screen sharing): use unlimited (the default)
/// LoomContainerConfiguration(serviceName: "MyApp")
///
/// // Messaging/chat apps: use a moderate policy
/// LoomContainerConfiguration(
///     serviceName: "MyApp",
///     messageRateLimitPolicy: .moderate
/// )
/// ```
///
/// > Important: Setting a rate limit that is too low for your app's message
/// > frequency will cause silent message drops. High-throughput features like
/// > trackpad input (60-120 Hz), screen sharing, or real-time audio relay
/// > should use ``unlimited`` or a sufficiently high custom policy.
public struct LoomMessageRateLimitPolicy: Sendable, Hashable {
    /// Maximum burst size (bucket capacity).
    public var maxBurst: Int

    /// Number of tokens refilled per second.
    public var refillRate: Double

    /// Creates a rate-limit policy.
    ///
    /// - Parameters:
    ///   - maxBurst: Peak messages accepted before throttling. Must be >= 1.
    ///   - refillRate: Tokens restored per second. Must be > 0.
    public init(maxBurst: Int = .max, refillRate: Double = .infinity) {
        self.maxBurst = max(maxBurst, 1)
        self.refillRate = max(refillRate, 0.1)
    }

    /// No rate limiting — all incoming messages are delivered. This is the default.
    ///
    /// Suitable for real-time apps such as remote control, screen sharing, or
    /// audio relay where message throughput must not be artificially limited.
    public static let `default` = unlimited

    /// No rate limiting.
    public static let unlimited = LoomMessageRateLimitPolicy(maxBurst: .max, refillRate: .infinity)

    /// Moderate rate limit: 500-message burst, 200 messages/sec steady state.
    ///
    /// Suitable for chat or document-sync apps where occasional high bursts
    /// are expected but sustained flooding is not.
    public static let moderate = LoomMessageRateLimitPolicy(maxBurst: 500, refillRate: 200.0)

    /// Strict rate limit: 100-message burst, 50 messages/sec steady state.
    ///
    /// Suitable for low-frequency control channels or apps that want aggressive
    /// protection against misbehaving peers.
    public static let strict = LoomMessageRateLimitPolicy(maxBurst: 100, refillRate: 50.0)
}

/// Token-bucket rate limiter for actor-isolated use inside LoomConnectionHandle.
package final class LoomTokenBucketRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBurst: Int
    private let refillRate: Double
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant

    package var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _droppedCount
    }
    private var _droppedCount: Int = 0

    package init(policy: LoomMessageRateLimitPolicy) {
        self.maxBurst = policy.maxBurst
        self.refillRate = policy.refillRate
        self.tokens = Double(policy.maxBurst)
        self.lastRefill = .now
    }

    /// Returns `true` if a token is available and consumed, `false` if the
    /// message should be dropped.
    package func tryConsume() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = ContinuousClock.now
        let elapsed = now - lastRefill
        let secondsElapsed = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(Double(maxBurst), tokens + secondsElapsed * refillRate)
        lastRefill = now

        if tokens >= 1.0 {
            tokens -= 1.0
            return true
        }
        _droppedCount += 1
        return false
    }
}

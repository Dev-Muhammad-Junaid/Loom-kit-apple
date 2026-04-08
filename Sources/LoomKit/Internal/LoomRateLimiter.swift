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
    public init(maxBurst: Int = 100, refillRate: Double = 50.0) {
        self.maxBurst = max(maxBurst, 1)
        self.refillRate = max(refillRate, 0.1)
    }

    /// Allows 100 messages in a burst, refilling at 50/second.
    public static let `default` = LoomMessageRateLimitPolicy()

    /// No rate limiting.
    public static let unlimited = LoomMessageRateLimitPolicy(maxBurst: .max, refillRate: .infinity)
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

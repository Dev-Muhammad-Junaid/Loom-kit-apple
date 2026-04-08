//
//  LoomRetryPolicy.swift
//  LoomKit
//
//  Exponential-backoff retry policy for automatically reconnecting
//  failed or unexpectedly dropped LoomKit connections.
//

import Foundation

/// Configures automatic reconnection behavior for connections managed
/// by ``LoomContainer``.
///
/// When a connection drops unexpectedly (state transitions to `.failed`),
/// LoomKit can automatically attempt to re-establish it using exponential
/// backoff with optional jitter. Set ``LoomContainerConfiguration/retryPolicy``
/// to control or disable this behavior.
public struct LoomRetryPolicy: Sendable, Hashable {
    /// Maximum number of consecutive retry attempts before giving up.
    public var maxAttempts: Int

    /// Base delay between the first retry attempt and the failure.
    public var baseDelay: Duration

    /// Upper bound on the computed backoff delay.
    public var maxDelay: Duration

    /// Multiplier applied to `baseDelay` for each successive attempt.
    public var multiplier: Double

    /// Fraction of the computed delay added as random jitter (0.0–1.0).
    public var jitterFraction: Double

    /// A connection must survive at least this long before it qualifies for
    /// automatic retry. Connections that fail faster than this threshold
    /// (e.g. rejected during an authorization dialog) are never retried.
    public var minimumEstablishedDuration: Duration

    /// Creates a retry policy.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum consecutive retries. Pass `0` to disable.
    ///   - baseDelay: Initial backoff duration.
    ///   - maxDelay: Backoff ceiling.
    ///   - multiplier: Exponential growth factor.
    ///   - jitterFraction: Random jitter fraction added to each delay.
    ///   - minimumEstablishedDuration: How long a connection must have been
    ///     alive before retry is considered. Defaults to 10 seconds.
    public init(
        maxAttempts: Int = 5,
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30),
        multiplier: Double = 2.0,
        jitterFraction: Double = 0.15,
        minimumEstablishedDuration: Duration = .seconds(10)
    ) {
        self.maxAttempts = max(maxAttempts, 0)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = max(multiplier, 1.0)
        self.jitterFraction = jitterFraction.clamped(to: 0.0 ... 1.0)
        self.minimumEstablishedDuration = minimumEstablishedDuration
    }

    /// Returns `true` when the policy allows no retries at all.
    public var isDisabled: Bool { maxAttempts == 0 }

    /// Computes the delay for a given zero-based attempt index.
    public func delay(forAttempt attempt: Int) -> Duration {
        guard attempt >= 0 else { return baseDelay }
        let exponential = Double(baseDelay.components.seconds)
            + Double(baseDelay.components.attoseconds) / 1e18
        let raw = exponential * pow(multiplier, Double(attempt))
        let maxSeconds = Double(maxDelay.components.seconds)
            + Double(maxDelay.components.attoseconds) / 1e18
        let capped = min(raw, maxSeconds)
        let jitter = capped * jitterFraction * Double.random(in: 0.0 ... 1.0)
        return .milliseconds(Int((capped + jitter) * 1000))
    }

    /// Sensible default: 5 attempts, 1 s base, 30 s cap.
    public static let `default` = LoomRetryPolicy()

    /// No automatic reconnection.
    public static let disabled = LoomRetryPolicy(maxAttempts: 0)
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

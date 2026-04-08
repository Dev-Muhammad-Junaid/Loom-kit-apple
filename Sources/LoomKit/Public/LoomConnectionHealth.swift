//
//  LoomConnectionHealth.swift
//  LoomKit
//
//  Observable connection-health snapshot surfaced through LoomConnectionHandle.
//

import Foundation
import Loom

/// Quality tier derived from the underlying transport path for UI display.
public enum LoomConnectionQuality: String, Sendable, Codable, Comparable {
    case excellent
    case good
    case fair
    case poor
    case unknown

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .excellent: 0
        case .good: 1
        case .fair: 2
        case .poor: 3
        case .unknown: 4
        }
    }
}

/// Periodic health snapshot for a LoomKit connection.
///
/// Updated automatically while the connection is active. Observe through
/// ``LoomConnectionHandle/healthUpdates`` or read the latest via
/// ``LoomConnectionHandle/latestHealth``.
public struct LoomConnectionHealthSnapshot: Sendable, Equatable {
    /// Timestamp of this snapshot.
    public let timestamp: Date
    /// Coarse quality tier inferred from path properties.
    public let quality: LoomConnectionQuality
    /// Whether the path is currently marked as expensive (e.g. cellular or hotspot).
    public let isExpensive: Bool
    /// Whether the path is currently constrained (e.g. Low Data Mode).
    public let isConstrained: Bool
    /// Whether IPv4 is available on the current path.
    public let supportsIPv4: Bool
    /// Whether IPv6 is available on the current path.
    public let supportsIPv6: Bool
    /// Primary interface kind inferred from the path.
    public let interfaceKind: String
    /// Reachability status of the underlying path.
    public let pathStatus: LoomSessionNetworkPathStatus

    public init(
        timestamp: Date = Date(),
        quality: LoomConnectionQuality = .unknown,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsIPv4: Bool = false,
        supportsIPv6: Bool = false,
        interfaceKind: String = "unknown",
        pathStatus: LoomSessionNetworkPathStatus = .unsatisfied
    ) {
        self.timestamp = timestamp
        self.quality = quality
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.interfaceKind = interfaceKind
        self.pathStatus = pathStatus
    }

    /// Derives a health snapshot from a transport-path snapshot.
    public init(from path: LoomSessionNetworkPathSnapshot) {
        self.init(
            timestamp: Date(),
            quality: Self.inferQuality(from: path),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            interfaceKind: Self.inferInterfaceKind(from: path),
            pathStatus: path.status
        )
    }

    private static func inferQuality(
        from path: LoomSessionNetworkPathSnapshot
    ) -> LoomConnectionQuality {
        guard path.status == .satisfied else { return .poor }
        if path.isConstrained { return .fair }
        if path.usesCellular { return path.isExpensive ? .fair : .good }
        if path.usesWiredEthernet { return .excellent }
        if path.usesWiFi { return path.isExpensive ? .good : .excellent }
        return .good
    }

    private static func inferInterfaceKind(
        from path: LoomSessionNetworkPathSnapshot
    ) -> String {
        if path.usesWiredEthernet { return "wired" }
        if path.usesWiFi { return "wifi" }
        if path.usesCellular { return "cellular" }
        if path.usesLoopback { return "loopback" }
        if path.usesOther { return "other" }
        return "unknown"
    }
}

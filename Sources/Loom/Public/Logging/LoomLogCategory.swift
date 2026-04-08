//
//  LoomLogCategory.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation

/// String-backed logging category used by Loom diagnostics and unified logging.
///
/// Loom keeps this type open so higher-level packages can layer product-specific
/// taxonomies on top without pushing those names back down into Loom.
public struct LoomLogCategory: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = Self.normalize(rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String {
        rawValue
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public extension LoomLogCategory {
    static let session: Self = "session"
    static let discovery: Self = "discovery"
    static let transport: Self = "transport"
    static let transfer: Self = "transfer"
    static let remoteSignaling: Self = "remote_signaling"
    static let identity: Self = "identity"
    static let security: Self = "security"
    static let trust: Self = "trust"
    static let cloud: Self = "cloud"
    static let bootstrap: Self = "bootstrap"
    static let ssh: Self = "ssh"
    static let wakeOnLAN: Self = "wake_on_lan"
    static let network: Self = "network"

    static let knownCategories: [Self] = [
        .session,
        .discovery,
        .transport,
        .transfer,
        .remoteSignaling,
        .identity,
        .security,
        .trust,
        .cloud,
        .bootstrap,
        .ssh,
        .wakeOnLAN,
        .network,
    ]

    static let defaultEnabledCategories: Set<Self> = [
        .discovery,
        .transport,
        .transfer,
        .remoteSignaling,
        .trust,
        .cloud,
    ]
}

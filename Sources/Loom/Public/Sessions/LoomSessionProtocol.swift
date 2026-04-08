//
//  LoomSessionProtocol.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation

/// Shared session boundary used by LoomKit, transfer flows, and shared-host virtual sessions.
public protocol LoomSessionProtocol: Sendable {
    /// Transport used by the session.
    var transportKind: LoomTransportKind { get async }

    /// Negotiated peer/session context once the handshake has completed.
    var context: LoomAuthenticatedSessionContext? { get async }

    /// Creates an additional observation stream for inbound logical streams.
    func makeIncomingStreamObserver() -> AsyncStream<LoomMultiplexedStream>

    /// Creates an observation stream for lifecycle state transitions.
    func makeStateObserver() async -> AsyncStream<LoomAuthenticatedSessionState>

    /// Creates an observation stream for transport-path changes.
    ///
    /// Implementations that don't expose a real network path may return an
    /// immediately-finishing stream.
    func makePathObserver() async -> AsyncStream<LoomSessionNetworkPathSnapshot>

    /// Opens a logical bidirectional stream on the session.
    func openStream(label: String?) async throws -> LoomMultiplexedStream

    /// Cancels the session and all attached streams.
    func cancel() async
}

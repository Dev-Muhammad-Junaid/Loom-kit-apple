//
//  LoomSessionTransport.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//

import Foundation

/// Abstraction over the framing/delivery layer beneath an authenticated Loom session.
///
/// `LoomFramedConnection` (TCP/QUIC) and `LoomReliableChannel` (UDP) both conform,
/// allowing `LoomAuthenticatedSession` to be transport-agnostic.
package protocol LoomSessionTransport: Sendable {
    /// Block until the underlying connection is ready for I/O.
    func awaitReady() async throws

    /// Send a complete message reliably (ordered, retransmitted if needed).
    func sendMessage(_ data: Data) async throws

    /// Receive the next complete reliable message.
    func receiveMessage(maxBytes: Int) async throws -> Data

    /// Send a message without reliability guarantees (fire-and-forget, no retransmission).
    func sendUnreliable(_ data: Data) async throws

    /// Receive the next unreliable message.
    func receiveUnreliable(maxBytes: Int) async throws -> Data
}

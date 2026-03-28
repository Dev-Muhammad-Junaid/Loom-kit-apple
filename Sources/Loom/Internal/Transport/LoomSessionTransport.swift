//
//  LoomSessionTransport.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//

import Foundation

package enum LoomSessionReceiveSemantics: Sendable {
    case singleLane
    case independentReliableAndUnreliable
}

/// Abstraction over the framing/delivery layer beneath an authenticated Loom session.
///
/// `LoomFramedConnection` (TCP/QUIC) and `LoomReliableChannel` (UDP) both conform,
/// allowing `LoomAuthenticatedSession` to be transport-agnostic.
package protocol LoomSessionTransport: Sendable {
    /// Describes whether the transport exposes one shared inbound message lane
    /// or genuinely separate reliable and unreliable receive lanes.
    var receiveSemantics: LoomSessionReceiveSemantics { get }

    /// Start the underlying connection and block until it is ready for I/O.
    ///
    /// Sets the `stateUpdateHandler` **before** calling `NWConnection.start(queue:)`
    /// so that no state transitions are lost — per Apple's Network.framework documentation.
    func startAndAwaitReady(queue: DispatchQueue) async throws

    /// Send a complete message reliably (ordered, retransmitted if needed).
    func sendMessage(_ data: Data) async throws

    /// Receive the next complete reliable message.
    func receiveMessage(maxBytes: Int) async throws -> Data

    /// Send a message without reliability guarantees (fire-and-forget, no retransmission).
    func sendUnreliable(_ data: Data) async throws

    /// Receive the next unreliable message.
    func receiveUnreliable(maxBytes: Int) async throws -> Data
}

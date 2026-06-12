//
//  LoomConnectionHandle+ControlMessage.swift
//  MirageControl – Shared
//
//  Single canonical path for shipping a `ControlMessage` over a Loom
//  connection. Centralizing this here prevents the iOS and Mac sides from
//  drifting on encoder configuration, and keeps the wire format under our
//  control even if Loom's default `send<T: Encodable>` overload changes.
//

import Foundation
import LoomKit

/// Shared coding utilities for the `ControlMessage` wire format.
///
/// `decoder` is the receive-side mirror of the shared encoder above: both
/// the Mac (`ControlReceiver.consumeMessages`) and the iOS
/// (`listenForHostMessages`) loops decode every inbound frame, and at
/// 120 Hz input rates constructing a fresh `JSONDecoder` per frame is
/// measurable allocator churn on the hottest path in the app.
/// `JSONDecoder` is Sendable and safe for concurrent use on Apple
/// platforms — decode state is per-call.
public enum ControlMessageCoding {
    /// One JSONEncoder reused for every outbound `ControlMessage`.
    /// Sendable on Apple platforms; encode state is per-call.
    public static let encoder = JSONEncoder()
    public static let decoder = JSONDecoder()
}

public extension LoomConnectionHandle {
    /// Encodes `message` with the shared MirageControl encoder and ships it
    /// on the default LoomKit message stream.
    ///
    /// Always prefer this over the generic `send<T: Encodable>` overload —
    /// the generic version constructs a fresh `JSONEncoder` per call, which
    /// (a) is wasteful at 120 Hz and (b) drifts away from the iOS/Mac
    /// inboxes that decode with their own configured `JSONDecoder`.
    func send(_ message: ControlMessage) async throws {
        let data = try ControlMessageCoding.encoder.encode(message)
        try await send(data)
    }
}

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

/// One JSONEncoder instance reused for every outbound `ControlMessage`.
/// `JSONEncoder` is documented as Sendable on Apple platforms — we only
/// touch it from `send`, so the cost is amortized across every send call.
private let mirageControlEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    return encoder
}()

public extension LoomConnectionHandle {
    /// Encodes `message` with the shared MirageControl encoder and ships it
    /// on the default LoomKit message stream.
    ///
    /// Always prefer this over the generic `send<T: Encodable>` overload —
    /// the generic version constructs a fresh `JSONEncoder` per call, which
    /// (a) is wasteful at 120 Hz and (b) drifts away from the iOS/Mac
    /// inboxes that decode with their own configured `JSONDecoder`.
    func send(_ message: ControlMessage) async throws {
        let data = try mirageControlEncoder.encode(message)
        try await send(data)
    }
}

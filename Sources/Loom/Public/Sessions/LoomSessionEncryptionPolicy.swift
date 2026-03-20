//
//  LoomSessionEncryptionPolicy.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//

/// Controls whether a Loom authenticated session requires payload encryption.
public enum LoomSessionEncryptionPolicy: Sendable {
    /// Encryption is required. Handshake fails if the peer does not support it.
    case required
    /// Encryption is preferred. Used when both peers negotiate it, skipped otherwise.
    case optional
}

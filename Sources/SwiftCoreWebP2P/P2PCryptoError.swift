// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

public enum P2PCryptoError: Error, Sendable, Equatable {
    /// The payload is too short to be a sealed message.
    case malformedSealedPayload
    /// Authentication failed: the data, its type or id, or the key is not what the sender sealed.
    case authenticationFailed
    /// The counter is not the next expected one: a replayed, reordered or dropped message.
    case unexpectedCounter
    /// The handshake salt was empty: it must bind the handshake.
    case emptySalt
    /// Both sides presented the same public key (a reflected key), so their roles cannot be told apart.
    case identicalPublicKeys
    /// The send counter is exhausted; the connection must be re-established with fresh keys.
    case counterExhausted
    /// The plaintext plus `P2PSecureChannel.overhead` would exceed `P2PFraming.maxMessageSize`.
    case payloadTooLarge
}

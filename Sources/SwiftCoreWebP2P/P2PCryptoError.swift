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
    /// The counter is not greater than the last accepted one: a replayed or reordered message.
    case replayedOrReordered
    /// The send counter is exhausted; the connection must be re-established with fresh keys.
    case counterExhausted
    /// The plaintext plus `P2PSecureChannel.overhead` would exceed `P2PFraming.maxMessageSize`.
    case payloadTooLarge
}

// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import CryptoKit
import Foundation

/// The two directional keys of one connection. Derive them from a *fresh* key agreement per connection (the
/// pairing step does this with ephemeral keys), never reuse them across connections: the message counter restarts at
/// zero for every new set of keys, and reusing a key with a restarted counter would repeat nonces.
public struct P2PSessionKeys: Sendable {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey

    /// Test seam and escape hatch for callers that agree on keys another way.
    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    /// X25519 agreement followed by HKDF-SHA256. `salt` must bind the handshake (both ephemeral public keys, in
    /// initiator-then-responder order, plus anything else both peers agreed on) so a different handshake never
    /// yields the same keys. Output is two 32-byte keys, one per direction.
    public init(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey,
        salt: Data,
        role: P2PRole
    ) throws {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        func key(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(label.utf8), outputByteCount: 32)
        }
        let initiatorToResponder = key("SwiftCoreWeb P2P v1 initiator->responder")
        let responderToInitiator = key("SwiftCoreWeb P2P v1 responder->initiator")
        switch role {
        case .initiator: self.init(sendKey: initiatorToResponder, receiveKey: responderToInitiator)
        case .responder: self.init(sendKey: responderToInitiator, receiveKey: initiatorToResponder)
        }
    }
}

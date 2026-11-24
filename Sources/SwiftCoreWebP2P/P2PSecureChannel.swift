// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import CryptoKit
import Foundation

/// End-to-end encryption of messages, on top of the transport's own security. One instance per connection and
/// per side; it holds the counters, so it is neither copyable (a copy would seal with the same counter, repeating a
/// nonce) nor shareable without an owner: wrap it in an actor.
///
/// Keys: X25519 agreement, then HKDF-SHA256 into one 32-byte key per direction. Pass the *ephemeral* private key
/// generated for this connection and `salt` binding the whole handshake (both public keys and anything else the
/// peers agreed on): keys must never be reused across connections, because the counters restart at zero.
/// Which side sends with which key is decided by the public keys alone (the side with the lexicographically smaller
/// raw public key is the "initiator"), so two peers can never both pick the same direction, even on a
/// simultaneous open.
///
/// A sealed payload is `counter (8 bytes, big-endian) || ChaCha20-Poly1305 ciphertext || tag (16 bytes)`:
/// - nonce = 4 zero bytes || counter, so a key never sees a nonce twice;
/// - the authenticated additional data is `version || message type || message id`, so a relay cannot change the
///   type, swap ids or reorder undetected; a truncated or extended message fails the tag;
/// - the receiver accepts exactly the next counter (0, 1, 2, ...): a replay, a reordering or a dropped message
///   ends the connection. This needs the sender to seal and send one message at a time, all its frames before the
///   next message's, so messages complete in the order they were sealed.
/// A relay can still cut the connection short; closing needs its own authenticated message (pairing's concern).
public struct P2PSecureChannel: ~Copyable, Sendable {
    /// Bytes a sealed payload adds to the plaintext (counter + tag): the largest plaintext is
    /// `P2PFraming.maxMessageSize - overhead`.
    public static let overhead = 8 + 16

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64
    private var expectedReceiveCounter: UInt64 = 0

    public init(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey,
        salt: Data
    ) throws {
        guard !salt.isEmpty else { throw P2PCryptoError.emptySalt }
        let own = privateKey.publicKey.rawRepresentation
        let peer = peerPublicKey.rawRepresentation
        guard own != peer else { throw P2PCryptoError.identicalPublicKeys }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        func key(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(label.utf8), outputByteCount: 32)
        }
        let initiatorToResponder = key("SwiftCoreWeb P2P v1 initiator->responder")
        let responderToInitiator = key("SwiftCoreWeb P2P v1 responder->initiator")
        let isInitiator = own.lexicographicallyPrecedes(peer)
        self.init(
            sendKey: isInitiator ? initiatorToResponder : responderToInitiator,
            receiveKey: isInitiator ? responderToInitiator : initiatorToResponder
        )
    }

    /// Also the seam for tests that need a counter near its limit.
    init(sendKey: SymmetricKey, receiveKey: SymmetricKey, sendCounter: UInt64 = 0) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.sendCounter = sendCounter
    }

    /// Returns `message` with its payload sealed. Type and id stay readable (they route the message).
    public mutating func seal(_ message: P2PMessage) throws -> P2PMessage {
        guard message.payload.count + Self.overhead <= P2PFraming.maxMessageSize else { throw P2PCryptoError.payloadTooLarge }
        guard sendCounter < UInt64.max else { throw P2PCryptoError.counterExhausted }
        let counter = sendCounter
        sendCounter += 1
        let box = try ChaChaPoly.seal(
            message.payload,
            using: sendKey,
            nonce: Self.nonce(counter),
            authenticating: Self.associatedData(of: message)
        )
        var sealed = Data(capacity: 8 + message.payload.count + 16)
        withUnsafeBytes(of: counter.bigEndian) { sealed.append(contentsOf: $0) }
        sealed.append(box.ciphertext)
        sealed.append(box.tag)
        return P2PMessage(type: message.type, id: message.id, payload: sealed)
    }

    /// Returns `message` with its payload opened, or throws; any throw means the connection must be closed.
    public mutating func open(_ message: P2PMessage) throws -> P2PMessage {
        let sealed = Data(message.payload)
        guard sealed.count >= 8 + 16 else { throw P2PCryptoError.malformedSealedPayload }
        let counter = sealed.bigEndian(at: 0, as: UInt64.self)
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(
                nonce: Self.nonce(counter),
                ciphertext: sealed[8..<(sealed.count - 16)],
                tag: sealed[(sealed.count - 16)...]
            )
        } catch {
            throw P2PCryptoError.malformedSealedPayload
        }
        // Authenticate first: an attacker must not be able to probe the counter state with forged messages.
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: Self.associatedData(of: message))
        } catch {
            throw P2PCryptoError.authenticationFailed
        }
        guard counter == expectedReceiveCounter else { throw P2PCryptoError.unexpectedCounter }
        expectedReceiveCounter += 1
        return P2PMessage(type: message.type, id: message.id, payload: plaintext)
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    private static func associatedData(of message: P2PMessage) -> Data {
        var data = Data([P2PFraming.version, message.type.rawValue])
        withUnsafeBytes(of: message.id.bigEndian) { data.append(contentsOf: $0) }
        return data
    }
}

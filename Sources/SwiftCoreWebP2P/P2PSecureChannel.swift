// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import CryptoKit
import Foundation

/// End-to-end encryption of messages, on top of the transport's own security. One instance per connection and
/// per side; it holds the counters, so it is a value that its single owner mutates (wrap it in an actor to share).
///
/// A sealed payload is `counter (8 bytes, big-endian) || ChaCha20-Poly1305 ciphertext || tag (16 bytes)`:
/// - nonce = 4 zero bytes || counter, so a key never sees a nonce twice (the counter only goes up);
/// - the authenticated additional data is `version || message type || message id`, so a relay cannot change the
///   type, swap ids or reorder undetected; a truncated or extended message fails the tag;
/// - the receiver accepts only a counter greater than the last one it accepted: the transport is ordered, so
///   anything else is a replay or a reordering and ends the connection.
public struct P2PSecureChannel: Sendable {
    /// Bytes a sealed payload adds to the plaintext (counter + tag): the largest plaintext is
    /// `P2PFraming.maxMessageSize - overhead`.
    public static let overhead = 8 + 16

    private let keys: P2PSessionKeys
    private var sendCounter: UInt64 = 0
    private var lastReceivedCounter: UInt64?

    public init(keys: P2PSessionKeys) {
        self.keys = keys
    }

    /// Returns `message` with its payload sealed. Type and id stay readable (they route the message).
    public mutating func seal(_ message: P2PMessage) throws -> P2PMessage {
        guard message.payload.count + Self.overhead <= P2PFraming.maxMessageSize else { throw P2PCryptoError.payloadTooLarge }
        guard sendCounter < UInt64.max else { throw P2PCryptoError.counterExhausted }
        let counter = sendCounter
        sendCounter += 1
        let box = try ChaChaPoly.seal(
            message.payload,
            using: keys.sendKey,
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
            plaintext = try ChaChaPoly.open(box, using: keys.receiveKey, authenticating: Self.associatedData(of: message))
        } catch {
            throw P2PCryptoError.authenticationFailed
        }
        if let last = lastReceivedCounter, counter <= last { throw P2PCryptoError.replayedOrReordered }
        lastReceivedCounter = counter
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

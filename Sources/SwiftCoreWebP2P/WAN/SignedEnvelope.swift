// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation
import NIOSSH

/// A payload with the Ed25519 signature of whoever made it and that signer's public key. The rendezvous relays these
/// without being able to alter them: a reader checks the signature and compares the key with the one it already trusts.
struct SignedEnvelope: Codable, Sendable, Equatable {
    /// The signed bytes, base64.
    let payload: String
    /// Ed25519 signature over the payload bytes, base64.
    let signature: String
    /// The signer's public key, OpenSSH form.
    let key: String

    static func sign(_ payload: Data, with key: Curve25519.Signing.PrivateKey) throws -> SignedEnvelope {
        SignedEnvelope(
            payload: payload.base64EncodedString(),
            signature: try key.signature(for: payload).base64EncodedString(),
            key: OpenSSHEd25519.string(for: key.publicKey)
        )
    }

    /// The payload and the signer's fingerprint when the signature is valid, `nil` otherwise.
    func verified() -> (payload: Data, signerFingerprint: String)? {
        guard let bytes = Data(base64Encoded: payload), let signatureBytes = Data(base64Encoded: signature),
              let publicKey = OpenSSHEd25519.publicKey(from: key), publicKey.isValidSignature(signatureBytes, for: bytes),
              let ssh = try? NIOSSHPublicKey(openSSHPublicKey: key) else { return nil }
        return (bytes, TunnelFingerprint.of(ssh))
    }
}

/// The OpenSSH text form of an Ed25519 public key (`ssh-ed25519 <base64 of the wire encoding>`).
enum OpenSSHEd25519 {
    private static let name = Data("ssh-ed25519".utf8)

    static func string(for key: Curve25519.Signing.PublicKey) -> String {
        var wire = lengthPrefixed(name)
        wire.append(lengthPrefixed(key.rawRepresentation))
        return "ssh-ed25519 " + wire.base64EncodedString()
    }

    static func publicKey(from text: String) -> Curve25519.Signing.PublicKey? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, parts[0] == "ssh-ed25519", let wire = Data(base64Encoded: String(parts[1])) else { return nil }
        var offset = 0
        func field() -> Data? {
            guard offset + 4 <= wire.count else { return nil }
            let length = wire[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard offset + 4 + length <= wire.count else { return nil }
            defer { offset += 4 + length }
            return Data(wire[(offset + 4)..<(offset + 4 + length)])
        }
        guard field() == name, let raw = field(), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        var out = Data((0..<4).map { UInt8((data.count >> (24 - 8 * $0)) & 0xFF) })
        out.append(data)
        return out
    }
}

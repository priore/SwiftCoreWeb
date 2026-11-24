// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation
import NIOSSH

/// The identity of an SSH public key, in the form OpenSSH prints: `SHA256:` followed by the unpadded base64 of the
/// SHA-256 of the key's wire encoding. It is what the pairing QR carries and what a client pins.
public enum TunnelFingerprint {
    /// The first 12 characters of a fingerprint without its `SHA256:` prefix: short enough to compare by eye on two screens.
    public static func short(_ fingerprint: String) -> String {
        String(fingerprint.replacingOccurrences(of: "SHA256:", with: "").prefix(12))
    }

    public static func of(_ key: NIOSSHPublicKey) -> String {
        let wire = Data(base64Encoded: String(openSSHPublicKey: key).split(separator: " ").dropFirst().first.map(String.init) ?? "") ?? Data()
        let digest = Data(SHA256.hash(data: wire)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + digest
    }
}

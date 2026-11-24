// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOSSH

/// The SSH user name of a device: its public key (OpenSSH form), base64url without padding. During pairing the host
/// reads the key to register from it; afterwards the key is proven by the SSH signature and the name is ignored.
enum DeviceUsername {
    static func encode(_ key: NIOSSHPublicKey) -> String {
        Data(String(openSSHPublicKey: key).utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ username: String) -> NIOSSHPublicKey? {
        var base64 = username.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8) else { return nil }
        return try? NIOSSHPublicKey(openSSHPublicKey: text)
    }
}

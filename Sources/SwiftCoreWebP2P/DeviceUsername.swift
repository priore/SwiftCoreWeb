// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOSSH

/// The SSH user name of a device: its public key (OpenSSH form), optionally followed by the name the device gives itself
/// (the key's comment field), base64url without padding. During pairing the host reads the key to register from it, and
/// the name to show in its list of devices; afterwards the key is proven by the SSH signature and the user name is ignored.
/// The name is only a label chosen by the device: it is never used to decide anything.
enum DeviceUsername {
    static func encode(_ key: NIOSSHPublicKey, name: String? = nil) -> String {
        let text = String(openSSHPublicKey: key) + (DeviceName.cleaned(name).map { " " + $0 } ?? "")
        return Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ username: String) -> NIOSSHPublicKey? {
        guard let text = text(of: username) else { return nil }
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return try? NIOSSHPublicKey(openSSHPublicKey: parts[0] + " " + parts[1])
    }

    /// The name the device gave itself, cleaned; `nil` when it sent none.
    static func name(of username: String) -> String? {
        guard let text = text(of: username) else { return nil }
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        return parts.count == 3 ? DeviceName.cleaned(String(parts[2])) : nil
    }

    private static func text(of username: String) -> String? {
        var base64 = username.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

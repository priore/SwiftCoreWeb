// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftCoreWeb

/// Where the tunnel keeps its secrets (the host's private key, the list of paired devices, a client's identity).
/// The default is the Keychain; nothing the tunnel keeps is ever written to a file.
public protocol TunnelSecretStorage: Sendable {
    func read(_ key: String) -> String?
    @discardableResult func write(_ value: String, forKey key: String) -> Bool
}

/// The Keychain, through the framework's `SecretStore`, under a service name of its own.
public struct KeychainTunnelStorage: TunnelSecretStorage {
    private let service: String

    public init(service: String = "SwiftCoreWebP2P") {
        self.service = service
    }

    public func read(_ key: String) -> String? {
        SecretStore.read(key, service: service)
    }

    @discardableResult
    public func write(_ value: String, forKey key: String) -> Bool {
        SecretStore.write(value, forKey: key, service: service)
    }
}

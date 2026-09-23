// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import Security

/// Reads secrets (JWT keys, `.p12` passwords) from the iOS Keychain.
///
/// Secrets never come from `appsettings.json` — this is the only source the
/// framework reads them from, using the system Security framework (no
/// third-party crypto or storage dependency).
public enum SecretStore {
    /// Reads a generic-password secret stored under `key` for this app's
    /// service identifier.
    ///
    /// - Returns: The secret's UTF-8 string value, or `nil` if no item is
    ///   stored under that key.
    public static func read(_ key: String, service: String = Bundle.main.bundleIdentifier ?? "SwiftCoreWeb") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Writes (or overwrites) a secret under `key` for this app's service
    /// identifier. Intended for setup/onboarding flows, not request-path use.
    @discardableResult
    public static func write(_ value: String, forKey key: String, service: String = Bundle.main.bundleIdentifier ?? "SwiftCoreWeb") -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

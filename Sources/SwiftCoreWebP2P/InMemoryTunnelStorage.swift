// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOConcurrencyHelpers

/// Keeps secrets in memory only: for tests, and for hosts that pair again after every launch.
public final class InMemoryTunnelStorage: TunnelSecretStorage {
    private let values = NIOLockedValueBox<[String: String]>([:])

    public init() {}

    public func read(_ key: String) -> String? {
        values.withLockedValue { $0[key] }
    }

    @discardableResult
    public func write(_ value: String, forKey key: String) -> Bool {
        values.withLockedValue { $0[key] = value }
        return true
    }
}

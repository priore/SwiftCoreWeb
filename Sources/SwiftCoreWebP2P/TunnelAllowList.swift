// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// The only destinations the tunnel will connect to on behalf of a peer. Without it the host would be an open proxy.
public struct TunnelAllowList: Sendable, Equatable {
    public let host: String
    public let port: Int

    /// Permits exactly `host:port`. For the SCW listener that is `127.0.0.1` and its port.
    public init(host: String = "127.0.0.1", port: Int) {
        self.host = host
        self.port = port
    }

    public func permits(host: String, port: Int) -> Bool {
        host == self.host && port == self.port
    }
}

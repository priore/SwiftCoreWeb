// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Where an extension connects to be served as a named peer (see `RequestIngress.peer`).
public struct PeerEndpoint: Sendable {
    /// The loopback port of the peer listener.
    public let port: Int
    let secret: String

    /// The line to write first on a connection to `port`, naming the peer `identity` (printable ASCII, no spaces).
    /// `HttpRequest.remoteAddress` then reads `identity`, so use a prefix that cannot be a real address.
    public func preamble(identity: String) -> String { "SCW-PEER \(secret) \(identity)\n" }
}

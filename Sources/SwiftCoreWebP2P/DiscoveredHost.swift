// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// A host announcing itself on the local network, as a device without a camera lists it to pair with.
///
/// Everything here comes from an unauthenticated announcement: `fingerprint` is a hint, and the connection is only trusted
/// after the user compares the host key it really presents (`SCWPeerConnection.pair(code:with:confirm:)`).
public struct DiscoveredHost: Sendable, Equatable, Identifiable {
    /// The service name the host announced (the name given to `useP2P(name:)`, or the machine's).
    public let name: String
    public let host: String
    public let port: Int
    public let appPort: Int
    public let fingerprint: String
    public var id: String { fingerprint + "@" + host }
}

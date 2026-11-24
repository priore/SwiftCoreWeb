// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Whether peer-to-peer access is on (`builder.useP2P(_:)`: the whole feature) or reachable for a route or group
/// (`app.useP2P(_:)`, `app.useP2P(_:_:)`, `RouteGroup.useP2P(_:)`: which paths paired devices may reach).
public enum P2PMode: Sendable, Equatable {
    case enable
    case disable
}

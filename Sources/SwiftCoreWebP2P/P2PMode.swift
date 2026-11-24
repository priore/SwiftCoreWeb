// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Whether routes are reachable over the peer-to-peer transport. Set as the default for every route with
/// `builder.useP2P(_:)` and overridden per route.
public enum P2PMode: Sendable, Equatable {
    case enable
    case disable
}

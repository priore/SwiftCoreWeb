// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Whether the peer-to-peer transport is active for the whole app, set with `builder.useP2P(_:)`.
/// Per-route exposure is not supported.
public enum P2PMode: Sendable, Equatable {
    case enable
    case disable
}

// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Which side of the connection this peer is. Fixed by who opened it, so both sides agree on the direction of each key.
public enum P2PRole: Sendable {
    case initiator
    case responder
}

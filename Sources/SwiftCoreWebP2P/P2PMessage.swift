// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// What a message carries. The numeric values are part of the wire protocol (version 1): never renumber.
public enum P2PMessageType: UInt8, Sendable {
    case request = 1
    case response = 2
    case webSocketOpen = 3
    case webSocketMessage = 4
    case webSocketClose = 5
    case error = 6
}

/// One application message, before it is split into frames and after it is reassembled.
public struct P2PMessage: Sendable, Equatable {
    public let type: P2PMessageType
    /// Chosen by the sender; every frame of the message carries it. A reply reuses the id of its request.
    public let id: UInt64
    public let payload: Data

    public init(type: P2PMessageType, id: UInt64, payload: Data) {
        self.type = type
        self.id = id
        self.payload = payload
    }
}

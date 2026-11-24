// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Why a frame or message was refused. Any of these means the peer broke the protocol: drop the connection.
public enum P2PFramingError: Error, Sendable, Equatable {
    case messageTooLarge
    case truncatedFrame
    case unsupportedVersion(UInt8)
    case unknownMessageType(UInt8)
    case reservedBitsSet
    case lengthMismatch
    case unexpectedFragment
    case tooManyPartialMessages
    case bufferBudgetExceeded
}

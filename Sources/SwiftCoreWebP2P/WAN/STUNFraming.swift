// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore

/// Cuts a TCP byte stream into STUN messages: the header says how long each one is (RFC 8489 §6.2.2).
struct STUNFraming {
    private(set) var buffer = ByteBuffer()

    mutating func append(_ bytes: inout ByteBuffer) { buffer.writeBuffer(&bytes) }

    /// The next whole message, or `nil` when more bytes are needed.
    mutating func nextMessage() -> Data? {
        guard buffer.readableBytes >= STUNMessage.headerSize, let length = buffer.getInteger(at: buffer.readerIndex + 2, as: UInt16.self) else { return nil }
        let total = STUNMessage.headerSize + Int(length)
        guard buffer.readableBytes >= total, let bytes = buffer.readBytes(length: total) else { return nil }
        return Data(bytes)
    }

    /// Everything not yet consumed as a message.
    mutating func takeRemainder() -> ByteBuffer {
        let rest = buffer
        buffer = ByteBuffer()
        return rest
    }
}

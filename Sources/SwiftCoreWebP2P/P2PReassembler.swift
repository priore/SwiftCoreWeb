// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// Rebuilds messages from the frames of one connection, in arrival order. Frames of different messages may
/// interleave; the fragments of one message must arrive in order. Memory is bounded by
/// `P2PFraming.maxMessageSize` per message and `maxPartialMessages` messages at once.
public struct P2PReassembler: Sendable {
    private struct Partial {
        let type: P2PMessageType
        var nextIndex: UInt32 = 0
        var payload = Data()
    }

    private var partials: [UInt64: Partial] = [:]
    private let maxPartialMessages: Int

    public init(maxPartialMessages: Int = 64) {
        self.maxPartialMessages = maxPartialMessages
    }

    /// Feeds one complete frame. Returns the message when this frame finished it, `nil` when more are needed.
    /// A throw means the peer broke the protocol; the partial message it concerned is discarded.
    public mutating func accept(_ rawFrame: Data) throws -> P2PMessage? {
        let frame = Data(rawFrame) // zero-based indices
        guard frame.count >= P2PFraming.headerSize else { throw P2PFramingError.truncatedFrame }
        guard frame[0] == P2PFraming.version else { throw P2PFramingError.unsupportedVersion(frame[0]) }
        guard let type = P2PMessageType(rawValue: frame[1]) else { throw P2PFramingError.unknownMessageType(frame[1]) }
        guard frame[2] & ~P2PFraming.lastFragmentFlag == 0, frame[3] == 0 else { throw P2PFramingError.reservedBitsSet }

        let id = frame.bigEndian(at: 4, as: UInt64.self)
        let index = frame.bigEndian(at: 12, as: UInt32.self)
        let length = Int(frame.bigEndian(at: 16, as: UInt16.self))
        guard length <= P2PFraming.maxFragmentPayload, frame.count == P2PFraming.headerSize + length else {
            throw P2PFramingError.lengthMismatch
        }
        let isLast = frame[2] & P2PFraming.lastFragmentFlag != 0

        var partial: Partial
        if let existing = partials[id] {
            partial = existing
        } else {
            guard partials.count < maxPartialMessages else { throw P2PFramingError.tooManyPartialMessages }
            partial = Partial(type: type)
        }
        guard index == partial.nextIndex, type == partial.type else {
            partials[id] = nil
            throw P2PFramingError.unexpectedFragment
        }
        guard partial.payload.count + length <= P2PFraming.maxMessageSize else {
            partials[id] = nil
            throw P2PFramingError.messageTooLarge
        }

        partial.payload.append(frame[P2PFraming.headerSize...])
        partial.nextIndex += 1
        if isLast {
            partials[id] = nil
            return P2PMessage(type: type, id: id, payload: partial.payload)
        }
        partials[id] = partial
        return nil
    }
}

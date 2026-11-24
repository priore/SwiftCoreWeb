// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// Wire framing, protocol version 1. Kept independent of Apple frameworks so a client on any platform can
/// implement it from this description alone.
///
/// A message is split into frames of at most 32 KiB of payload. Each frame is an 18-byte header followed by
/// its payload; all integers are big-endian:
///
///     offset size field
///     0      1    version          = 1
///     1      1    message type     (P2PMessageType)
///     2      1    flags            bit 0 = last fragment of the message; other bits must be 0
///     3      1    reserved         must be 0
///     4      8    message id
///     12     4    fragment index   0, 1, 2, ... in order
///     16     2    payload length   0 ... 32768
public enum P2PFraming {
    public static let version: UInt8 = 1
    public static let headerSize = 18
    public static let maxFragmentPayload = 32 * 1024
    public static let maxMessageSize = 1024 * 1024
    static let lastFragmentFlag: UInt8 = 0x01

    /// Splits `message` into frames, in the order they must be sent. An empty payload is one empty frame.
    public static func encode(_ message: P2PMessage) throws -> [Data] {
        guard message.payload.count <= maxMessageSize else { throw P2PFramingError.messageTooLarge }
        let payload = Data(message.payload)
        let fragmentCount = max(1, (payload.count + maxFragmentPayload - 1) / maxFragmentPayload)
        return (0..<fragmentCount).map { index in
            let start = index * maxFragmentPayload
            let chunk = payload[start..<min(start + maxFragmentPayload, payload.count)]
            var frame = Data(capacity: headerSize + chunk.count)
            frame.append(version)
            frame.append(message.type.rawValue)
            frame.append(index == fragmentCount - 1 ? lastFragmentFlag : 0)
            frame.append(0)
            frame.append(bigEndian: message.id)
            frame.append(bigEndian: UInt32(index))
            frame.append(bigEndian: UInt16(chunk.count))
            frame.append(chunk)
            return frame
        }
    }
}

extension Data {
    fileprivate mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// The big-endian integer at `offset` (relative to the start of this data, which must be zero-based).
    func bigEndian<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T {
        (0..<MemoryLayout<T>.size).reduce(T.zero) { ($0 << 8) | T(self[offset + $1]) }
    }
}

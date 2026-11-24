// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore

/// Reads the one line a trusted extension sends before the HTTP bytes on the peer listener:
/// `SCW-PEER <secret> <identity>\n`. The secret is random per run and known only to the extensions, so a local process
/// cannot claim another identity. On success the identity is delivered through `promise` and the decoder removes itself;
/// bytes that arrived after the line are passed on to whatever was installed meanwhile (the HTTP decoder).
struct PeerPreambleDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    static let maxLineLength = 512

    let secret: String
    let promise: EventLoopPromise<String>
    /// Set once the line was accepted. The handler is removed on a later loop tick, and reads can arrive before that.
    private var accepted = false
    init(secret: String, promise: EventLoopPromise<String>) {
        self.secret = secret
        self.promise = promise
    }

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if accepted { return forward(&buffer, context) }
        guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            if buffer.readableBytes > Self.maxLineLength { reject(context) }
            return .needMoreData
        }
        let length = newline - buffer.readerIndex + 1
        guard length <= Self.maxLineLength, let line = buffer.readString(length: length) else {
            reject(context)
            return .needMoreData
        }
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "SCW-PEER", Self.constantTimeEquals(String(parts[1]), secret),
              !parts[2].isEmpty, parts[2].utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            reject(context)
            return .needMoreData
        }
        accepted = true
        promise.succeed(String(parts[2])) // synchronous: the HTTP handlers are in place before any byte is forwarded
        context.pipeline.removeHandler(context: context, promise: nil)
        // ByteToMessageHandler does not pass leftover bytes on by itself: forward what followed the line now.
        return forward(&buffer, context)
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        if accepted { return forward(&buffer, context) }
        if seenEOF { promise.fail(ServerEngineError.stopped) }
        return .needMoreData
    }

    private func forward(_ buffer: inout ByteBuffer, _ context: ChannelHandlerContext) -> DecodingState {
        if buffer.readableBytes > 0 { context.fireChannelRead(NIOAny(buffer.readSlice(length: buffer.readableBytes)!)) }
        return .needMoreData
    }

    private func reject(_ context: ChannelHandlerContext) {
        promise.fail(ServerEngineError.stopped)
        context.close(promise: nil)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

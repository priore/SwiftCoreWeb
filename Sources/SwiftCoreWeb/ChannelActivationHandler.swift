// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOCore

/// Runs `onActive` with the connection's remote address the moment the channel becomes active, before the first read: on NIO
/// Transport Services a connection has no remote address until then, so the pipeline that needs it is built here.
final class ChannelActivationHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    private let onActive: (String?) -> Void

    init(onActive: @escaping (String?) -> Void) { self.onActive = onActive }

    func channelActive(context: ChannelHandlerContext) {
        onActive(context.remoteAddress?.ipAddress)
        context.fireChannelActive()
        context.pipeline.removeHandler(self, promise: nil)
    }
}

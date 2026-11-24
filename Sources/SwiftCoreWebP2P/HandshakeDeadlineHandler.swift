// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOCore
import NIOSSH

/// Closes a connection that has not finished authenticating within `timeout`, so a socket that never speaks (or never
/// proves a key) cannot hold a slot forever.
final class HandshakeDeadlineHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = Any

    private let timeout: TimeAmount
    private var deadline: Scheduled<Void>?

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: timeout) { context.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        deadline?.cancel()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            deadline?.cancel()
            deadline = nil
        }
        context.fireUserInboundEventTriggered(event)
    }
}

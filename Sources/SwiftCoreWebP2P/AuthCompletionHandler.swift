// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOCore
import NIOSSH

/// Completes `promise` when the SSH user authentication succeeds, or fails it when the connection ends or errors
/// first (a rejected host key, a refused key, a dropped socket).
final class AuthCompletionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { promise.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(TunnelError.notConnected)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

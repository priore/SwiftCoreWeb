// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOCore

/// Relays bytes between two channels that live on the same event loop, with backpressure and half-close:
/// each handler writes what its partner reads, pauses its own reads while the partner's channel is not writable,
/// and passes on end-of-input and closure.
final class TunnelRelayHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private weak var partner: TunnelRelayHandler?
    private var context: ChannelHandlerContext?

    static func makePair() -> (TunnelRelayHandler, TunnelRelayHandler) {
        let first = TunnelRelayHandler()
        let second = TunnelRelayHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private init() {}

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let partner, let partnerContext = partner.context else { return context.close(promise: nil) }
        partnerContext.write(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
        if !partnerContext.channel.isWritable {
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in context.close(promise: nil) }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, let partnerContext = partner?.context {
            partnerContext.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in partnerContext.close(promise: nil) }
        }
        context.fireChannelWritabilityChanged()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.context?.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.context?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.context?.close(promise: nil)
        context.close(promise: nil)
    }
}

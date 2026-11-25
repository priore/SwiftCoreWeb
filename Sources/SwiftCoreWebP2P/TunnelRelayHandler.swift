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
final class TunnelRelayHandler: ChannelDuplexHandler, @unchecked Sendable { // both sides live on one event loop
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// Shared by the pair, so "one side already closed" survives the other handler being removed and freed.
    private final class PairState {
        var closed = false
    }

    private weak var partner: TunnelRelayHandler?
    private var context: ChannelHandlerContext?
    private let state: PairState

    static func makePair() -> (TunnelRelayHandler, TunnelRelayHandler) {
        let state = PairState()
        let first = TunnelRelayHandler(state: state)
        let second = TunnelRelayHandler(state: state)
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private init(state: PairState) {
        self.state = state
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // The partner's channel may have closed before this one existed (the local client gave up early).
        if state.closed { context.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let partner, let partnerContext = partner.context else { return context.close(promise: nil) }
        partnerContext.write(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
        if !partnerContext.channel.isWritable {
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in bound.value.close(promise: nil) }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, let partnerContext = partner?.context {
            let bound = NIOLoopBound(partnerContext, eventLoop: partnerContext.eventLoop)
            partnerContext.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in bound.value.close(promise: nil) }
        }
        context.fireChannelWritabilityChanged()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.closeAfterWrites(mode: .output)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.closed = true
        partner?.closeAfterWrites(mode: .all)
        context.fireChannelInactive()
    }

    /// Closes (or half-closes) this side only once what was already written has been sent: a plain close would drop the
    /// tail of a response that the other side finished sending an instant before it hung up.
    private func closeAfterWrites(mode: CloseMode) {
        guard let context else { return }
        let marker = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(capacity: 0)), promise: marker)
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        marker.futureResult.whenComplete { _ in bound.value.close(mode: mode, promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.context?.close(promise: nil)
        context.close(promise: nil)
    }
}

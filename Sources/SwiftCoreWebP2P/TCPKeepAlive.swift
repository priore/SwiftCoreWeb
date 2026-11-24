// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore
import NIOPosix

/// Tunes TCP keepalive so a peer that disappeared without closing (a phone leaving Wi-Fi, a sleeping Mac) is noticed in about
/// a minute and its connection, and the slot it holds, is released. The system default is two hours.
enum TCPKeepAlive {
    static let idleSeconds = 30
    static let intervalSeconds = 10
    static let probes = 3

    /// Turns keepalive on for `channel` with the values above.
    static func apply(to channel: Channel) -> EventLoopFuture<Void> {
        var futures = [channel.setOption(ChannelOptions.socketOption(.so_keepalive), value: 1)]
        #if canImport(Darwin)
        func tcp(_ name: Int32, _ value: Int) -> EventLoopFuture<Void> {
            channel.setOption(
                ChannelOptions.Types.SocketOption(level: NIOBSDSocket.OptionLevel(rawValue: IPPROTO_TCP), name: NIOBSDSocket.Option(rawValue: name)),
                value: CInt(value)
            )
        }
        futures += [tcp(TCP_KEEPALIVE, idleSeconds), tcp(0x101 /* TCP_KEEPINTVL */, intervalSeconds), tcp(0x102 /* TCP_KEEPCNT */, probes)]
        #endif
        return EventLoopFuture.andAllSucceed(futures, on: channel.eventLoop)
    }
}

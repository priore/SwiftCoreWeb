// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore

/// How long the connection steps wait before giving up. On the local network an address either answers at once or not at
/// all, so the waits are short; across the internet (a direct connection or the relay) a phone's radio can need seconds to
/// wake up and the path is longer, so they are wider. The defaults suit both; change them only for a reason.
public struct P2PTimeouts: Sendable, Equatable {
    /// Opening a TCP connection to an address on the local network (the remembered one, or one found by Bonjour).
    public var localConnect: TimeInterval = 4
    /// Opening a TCP connection across the internet (the relay, or a direct attempt's lookup).
    public var wideAreaConnect: TimeInterval = 10
    /// From the TCP connection to an authenticated SSH session, on the local network.
    public var localHandshake: TimeInterval = 15
    /// The same across the internet.
    public var wideAreaHandshake: TimeInterval = 30
    /// How long a direct connection (hole punching) is tried before the relay.
    public var directWindow: TimeInterval = 6
    /// A STUN lookup (connection and answer).
    public var stunLookup: TimeInterval = 5
    /// One request to the TURN server.
    public var turnRequest: TimeInterval = 8

    public static let `default` = P2PTimeouts()

    public init() {}

    var localConnectAmount: TimeAmount { .milliseconds(Int64(localConnect * 1000)) }
    var wideAreaConnectAmount: TimeAmount { .milliseconds(Int64(wideAreaConnect * 1000)) }
    var stunAmount: TimeAmount { .milliseconds(Int64(stunLookup * 1000)) }
    var turnAmount: TimeAmount { .milliseconds(Int64(turnRequest * 1000)) }
}

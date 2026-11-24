// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// One authenticated SSH connection to a host, over which forwarded channels are opened.
public final class SSHTunnelClient: Sendable {
    let group: EventLoopGroup
    let eventLoop: EventLoop
    private let connection = NIOLockedValueBox<Channel?>(nil)

    public init() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        self.eventLoop = group.next()
    }

    /// Connects and waits for authentication to finish. Fails when the host key is not `trustedHostKey` or the server
    /// refuses `key`.
    public func connect(
        host: String,
        port: Int,
        username: String,
        key: Curve25519.Signing.PrivateKey,
        trustedHostKey: @escaping @Sendable (NIOSSHPublicKey) -> Bool
    ) async throws {
        let privateKey = NIOSSHPrivateKey(ed25519Key: key)
        let authenticated = eventLoop.makePromise(of: Void.self)
        // Never wait forever for a host that accepts the socket but does not finish the handshake.
        let deadline = eventLoop.scheduleTask(in: .seconds(15)) { authenticated.fail(TunnelError.notConnected) }
        defer { deadline.cancel() }
        let bootstrap = ClientBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHClientConfiguration(
                        userAuthDelegate: PrivateKeyAuthDelegate(username: username, key: privateKey),
                        serverAuthDelegate: PinnedHostKeyDelegate(isTrusted: trustedHostKey)
                    )
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil))
                    try channel.pipeline.syncOperations.addHandler(AuthCompletionHandler(promise: authenticated))
                }
            }
        let channel = try await bootstrap.connect(host: host, port: port).get()
        do {
            try await authenticated.futureResult.get()
        } catch {
            try? await channel.close()
            throw error
        }
        connection.withLockedValue { $0 = channel }
    }

    /// Opens a `direct-tcpip` channel to `host:port` on the far side and runs `initialize` on it (on the connection's event loop).
    func openForwardedChannel(
        toHost host: String,
        port: Int,
        originator: SocketAddress,
        initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        guard let channel = connection.withLockedValue({ $0 }) else { throw TunnelError.notConnected }
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        try await channel.eventLoop.submit {
            let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            handler.createChannel(promise, channelType: .directTCPIP(.init(targetHost: host, targetPort: port, originatorAddress: originator))) { child, _ in
                initialize(child)
            }
        }.get()
        return try await promise.futureResult.get()
    }

    public func close() async {
        if let channel = connection.withLockedValue({ $0.take() }) { try? await channel.close() }
        try? await (group as? MultiThreadedEventLoopGroup)?.shutdownGracefully()
    }
}

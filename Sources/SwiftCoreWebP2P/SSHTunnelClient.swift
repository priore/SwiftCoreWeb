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
final class SSHTunnelClient: Sendable {
    let group: EventLoopGroup
    let eventLoop: EventLoop
    private let ownsGroup: Bool
    private let connection = NIOLockedValueBox<Channel?>(nil)

    /// With no `group` the client runs on a thread of its own and stops it on `close()`; a group passed in belongs to the
    /// caller (so a replacement client can run on the same event loop as the one it replaces).
    init(group shared: MultiThreadedEventLoopGroup? = nil) {
        let group = shared ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        ownsGroup = shared == nil
        self.group = group
        self.eventLoop = group.next()
    }

    /// Connects and waits for authentication to finish. Fails when the host key is not `trustedHostKey` or the server
    /// refuses `key`.
    func connect(
        host: String,
        port: Int,
        key: Curve25519.Signing.PrivateKey,
        credential: TunnelCredential,
        localPort: Int? = nil,
        connectTimeout: TimeAmount = .seconds(4),
        handshakeTimeout: TimeAmount = .seconds(15),
        trustedHostKey: @escaping @Sendable (NIOSSHPublicKey) async -> Bool
    ) async throws {
        let privateKey = NIOSSHPrivateKey(ed25519Key: key)
        let authenticated = eventLoop.makePromise(of: Void.self)
        // Never wait forever for a host that accepts the socket but does not finish the handshake.
        let deadline = eventLoop.scheduleTask(in: handshakeTimeout) { authenticated.fail(TunnelError.notConnected) }
        defer { deadline.cancel() }
        var bootstrap = ClientBootstrap(group: eventLoop)
            // An address that does not answer must not hold up the next way of reaching the host.
            .connectTimeout(connectTimeout)
            .channelInitializer { channel in
                TCPKeepAlive.apply(to: channel).flatMapThrowing {
                    let configuration = SSHClientConfiguration(
                        userAuthDelegate: CredentialAuthDelegate(key: privateKey, credential: credential),
                        serverAuthDelegate: PinnedHostKeyDelegate(isTrusted: trustedHostKey)
                    )
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil))
                    try channel.pipeline.syncOperations.addHandler(AuthCompletionHandler(promise: authenticated))
                }
            }
        if let localPort {
            // The same local port as a socket that learned its public mapping or is listening: hole punching needs it.
            bootstrap = bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socketOption(.so_reuseport), value: 1)
            do { bootstrap = try bootstrap.bind(to: SocketAddress(ipAddress: "0.0.0.0", port: localPort)) } catch {
                authenticated.fail(error)
                throw error
            }
        }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            authenticated.fail(error) // the promise must always be completed
            throw error
        }
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
        do {
            try await channel.eventLoop.submit {
                let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                handler.createChannel(promise, channelType: .directTCPIP(.init(targetHost: host, targetPort: port, originatorAddress: originator))) { child, _ in
                    initialize(child)
                }
            }.get()
        } catch {
            promise.fail(error) // the SSH connection is gone: the promise must still be completed
            throw error
        }
        return try await promise.futureResult.get()
    }

    func close() async {
        if let channel = connection.withLockedValue({ $0.take() }) { try? await channel.close() }
        if ownsGroup { try? await (group as? MultiThreadedEventLoopGroup)?.shutdownGracefully() }
    }

    /// Returns when the SSH connection ends (the host went away, the network changed, `close()`); at once when not connected.
    func waitUntilClosed() async {
        guard let channel = connection.withLockedValue({ $0 }) else { return }
        try? await channel.closeFuture.get()
    }
}

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

/// Accepts SSH connections from authorized peers and forwards each `direct-tcpip` channel to the allow-listed
/// destination (the local SCW listener). Nothing else is served: no shell, no exec, no other destinations.
public final class SSHTunnelServer: Sendable {
    private let hostKey: NIOSSHPrivateKey
    private let allowList: TunnelAllowList
    private let isAuthorized: @Sendable (NIOSSHPublicKey) -> Bool
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let listener = NIOLockedValueBox<Channel?>(nil)

    public init(
        hostKey: Curve25519.Signing.PrivateKey,
        allowList: TunnelAllowList,
        isAuthorized: @escaping @Sendable (NIOSSHPublicKey) -> Bool
    ) {
        self.hostKey = NIOSSHPrivateKey(ed25519Key: hostKey)
        self.allowList = allowList
        self.isAuthorized = isAuthorized
    }

    /// The public key a client pins when pairing.
    public var hostPublicKey: NIOSSHPublicKey { hostKey.publicKey }

    /// Starts listening and returns the bound port (`port: 0` picks a free one).
    @discardableResult
    public func start(host: String = "0.0.0.0", port: Int = 0) async throws -> Int {
        let hostKey = hostKey, allowList = allowList, isAuthorized = isAuthorized
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: PublicKeyAuthDelegate(isAuthorized: isAuthorized))
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(role: .server(configuration), allocator: channel.allocator) { child, channelType in
                            Self.forward(child, channelType, allowList: allowList)
                        }
                    )
                }
            }
        let channel = try await bootstrap.bind(host: host, port: port).get()
        listener.withLockedValue { $0 = channel }
        guard let bound = channel.localAddress?.port else { throw TunnelError.notConnected }
        return bound
    }

    public func stop() async {
        if let channel = listener.withLockedValue({ $0.take() }) { try? await channel.close() }
        try? await group.shutdownGracefully()
    }

    /// Connects an SSH child channel to its destination, or refuses it when it is not allow-listed.
    private static func forward(_ child: Channel, _ type: SSHChannelType, allowList: TunnelAllowList) -> EventLoopFuture<Void> {
        guard case .directTCPIP(let target) = type, allowList.permits(host: target.targetHost, port: target.targetPort) else {
            return child.eventLoop.makeFailedFuture(TunnelError.destinationNotAllowed)
        }
        let (sshSide, targetSide) = TunnelRelayHandler.makePair()
        return child.pipeline.addHandlers([SSHDataCodec(), sshSide]).flatMap {
            ClientBootstrap(group: child.eventLoop)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .connect(host: target.targetHost, port: target.targetPort)
        }.flatMap { targetChannel in
            targetChannel.pipeline.addHandler(targetSide)
        }
    }
}

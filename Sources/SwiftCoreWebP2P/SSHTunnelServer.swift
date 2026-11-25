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
import SwiftCoreWeb

/// Accepts SSH connections from authorized peers and forwards each `direct-tcpip` channel to the allow-listed
/// destination (the local SCW listener). Nothing else is served: no shell, no exec, no other destinations.
public final class SSHTunnelServer: Sendable {
    private let pairing: PairingManager
    private let registry = ConnectionRegistry()
    private let boundPort = NIOLockedValueBox<Int?>(nil)
    private let stopped = NIOLockedValueBox(false)
    /// Every connection being served, authenticated or not, so `stop()` can end the ones that are not on this server's own group.
    private let serving = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])
    /// The port the tunnel listens on, once started.
    var port: Int? { boundPort.withLockedValue { $0 } }
    private let allowList: TunnelAllowList
    private let handshakeTimeout: TimeAmount
    private let maxConnections: Int
    private let peer: PeerEndpoint?
    private let openConnections = NIOLockedValueBox(0)
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let listener = NIOLockedValueBox<Channel?>(nil)

    public init(
        pairing: PairingManager,
        allowList: TunnelAllowList,
        handshakeTimeout: TimeAmount = .seconds(10),
        maxConnections: Int = 64,
        peer: PeerEndpoint? = nil
    ) {
        self.peer = peer
        self.handshakeTimeout = handshakeTimeout
        self.maxConnections = maxConnections
        self.pairing = pairing
        self.allowList = allowList
    }

    /// Starts listening and returns the bound port (`port: 0` picks a free one). The default `host` listens on every IPv4
    /// interface (cellular and VPN included): that is what lets a paired device reach the host, and only paired keys get
    /// in. Unauthenticated sockets still use connection slots (`maxConnections`) until the handshake deadline closes them.
    @discardableResult
    public func start(host: String = "0.0.0.0", port: Int = 0) async throws -> Int {
        stopped.withLockedValue { $0 = false }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Outgoing connections made from this same port (hole punching) need it to be shareable.
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseport), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeFailedFuture(TunnelError.notConnected) }
                return TCPKeepAlive.apply(to: channel).flatMap { self.serve(channel) }
            }
        let channel = try await bootstrap.bind(host: host, port: port).get()
        pairing.setRevocationHandler { [registry] deviceID in registry.closeAll(deviceID: deviceID) }
        listener.withLockedValue { $0 = channel }
        guard let bound = channel.localAddress?.port else { throw TunnelError.notConnected }
        boundPort.withLockedValue { $0 = bound }
        return bound
    }

    /// Serves SSH on a channel that was accepted elsewhere (the listener above, or a relayed connection): applies the
    /// connection cap, the handshake deadline and the pairing authentication, then forwards the allow-listed channels.
    /// Fails, leaving the channel for the caller to close, when the host is at capacity.
    func serve(_ channel: Channel) -> EventLoopFuture<Void> {
        if stopped.withLockedValue({ $0 }) { return channel.eventLoop.makeFailedFuture(TunnelError.notConnected) }
        let pairing = pairing, registry = registry, allowList = allowList, peer = peer, stopped = stopped
        let handshakeTimeout = handshakeTimeout, maxConnections = maxConnections, openConnections = openConnections
        // Caps the tunnel's total connections (authenticated ones included): the host's capacity, and a bound on
        // what unauthenticated sockets can occupy.
        let admitted = openConnections.withLockedValue { count -> Bool in
            guard count < maxConnections else { return false }
            count += 1
            return true
        }
        guard admitted else { return channel.eventLoop.makeFailedFuture(TunnelError.tooManyConnections) }
        let serving = serving, key = ObjectIdentifier(channel)
        serving.withLockedValue { $0[key] = channel }
        channel.closeFuture.whenComplete { _ in
            openConnections.withLockedValue { $0 -= 1 }
            serving.withLockedValue { _ = $0.removeValue(forKey: key) }
        }
        return channel.eventLoop.makeCompletedFuture {
            let deadline = HandshakeDeadline(channel: channel, timeout: handshakeTimeout)
            let configuration = SSHServerConfiguration(
                hostKeys: [pairing.hostPrivateKey],
                userAuthDelegate: PairingAuthDelegate(pairing: pairing, onAuthenticated: { deviceID in
                    deadline.cancel()
                    registry.add(channel, deviceID: deviceID)
                    // Stopped while this connection was still in its handshake (a relayed or punched one is not on this server's group).
                    if stopped.withLockedValue({ $0 }) { channel.close(promise: nil) }
                    // Revoked between the check and the registration: closeAll would have missed this connection.
                    if !pairing.isPaired(deviceID: deviceID) { channel.close(promise: nil) }
                })
            )
            try channel.pipeline.syncOperations.addHandler(
                NIOSSHHandler(role: .server(configuration), allocator: channel.allocator) { child, channelType in
                    Self.forward(child, channelType, allowList: allowList, registry: registry, peer: peer)
                }
            )
        }
    }

    public func stop() async {
        stopped.withLockedValue { $0 = true }
        registry.closeEverything()
        for channel in serving.withLockedValue({ Array($0.values) }) { channel.close(promise: nil) } // relayed and punched ones too
        pairing.setRevocationHandler(nil)
        if let channel = listener.withLockedValue({ $0.take() }) { try? await channel.close() }
        try? await group.shutdownGracefully()
    }

    /// Connects an SSH child channel to its destination, or refuses it when it is not allow-listed.
    private static func forward(
        _ child: Channel,
        _ type: SSHChannelType,
        allowList: TunnelAllowList,
        registry: ConnectionRegistry,
        peer: PeerEndpoint?
    ) -> EventLoopFuture<Void> {
        guard case .directTCPIP(let target) = type, allowList.permits(host: target.targetHost, port: target.targetPort) else {
            return child.eventLoop.makeFailedFuture(TunnelError.destinationNotAllowed)
        }
        let (sshSide, targetSide) = TunnelRelayHandler.makePair()
        // With a peer listener the connection goes there, announcing which paired device it belongs to, so the app sees
        // that device (not 127.0.0.1) as the client. Without one (tests of the tunnel alone) it goes straight to the target.
        let destination: (host: String, port: Int)
        let preamble: ByteBuffer?
        if let peer {
            guard let parent = child.parent, let deviceID = registry.deviceID(for: parent) else {
                return child.eventLoop.makeFailedFuture(TunnelError.notConnected)
            }
            destination = ("127.0.0.1", peer.port)
            preamble = child.allocator.buffer(string: peer.preamble(identity: "p2p:" + deviceID))
        } else {
            destination = (host: target.targetHost, port: target.targetPort)
            preamble = nil
        }
        // The target side is installed as the channel is created, so a close during the connect is not missed.
        let targetSideBox = UncheckedSendableBox(targetSide)
        return child.pipeline.addHandlers([SSHDataCodec(), sshSide]).flatMap {
            ClientBootstrap(group: child.eventLoop)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { $0.pipeline.addHandler(targetSideBox.value) }
                .connect(host: destination.host, port: destination.port)
        }.flatMap { target -> EventLoopFuture<Void> in
            guard let preamble else { return child.eventLoop.makeSucceededVoidFuture() }
            return target.writeAndFlush(preamble)
        }
    }
}

// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Listens on `127.0.0.1` and forwards every accepted connection through the tunnel to `destination`, so any HTTP
/// client can talk to the remote SCW by pointing at `http://127.0.0.1:<port>`.
final class LoopbackProxy: Sendable {
    private let client: SSHTunnelClient
    private let destination: TunnelAllowList
    private let listener = NIOLockedValueBox<Channel?>(nil)

    init(client: SSHTunnelClient, destination: TunnelAllowList) {
        self.client = client
        self.destination = destination
    }

    /// Starts listening and returns the loopback port (`port: 0` picks a free one).
    @discardableResult
    func start(port: Int = 0) async throws -> Int {
        let client = client, destination = destination
        let bootstrap = ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            // Reads stay off until the tunnel channel exists, so no byte is read before it can be relayed.
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { local in
                let (localSide, tunnelSide) = TunnelRelayHandler.makePair()
                let originator = local.remoteAddress ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                // The relay handlers are bound to their channel's event loop; they are handed over once, here.
                let tunnelSideBox = UncheckedSendableBox(tunnelSide)
                return local.pipeline.addHandler(localSide).map {
                    Task {
                        do {
                            _ = try await client.openForwardedChannel(toHost: destination.host, port: destination.port, originator: originator) { child in
                                child.pipeline.addHandlers([SSHDataCodec(), tunnelSideBox.value])
                            }
                            local.eventLoop.execute { _ = local.setOption(ChannelOptions.autoRead, value: true) }
                        } catch {
                            local.close(promise: nil)
                        }
                    }
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        listener.withLockedValue { $0 = channel }
        guard let bound = channel.localAddress?.port else { throw TunnelError.notConnected }
        return bound
    }

    func stop() async {
        if let channel = listener.withLockedValue({ $0.take() }) { try? await channel.close() }
    }
}

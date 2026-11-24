// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// The client side: pairs with a host once, then reaches its SCW app through a loopback URL that any HTTP client can use.
///
/// ```swift
/// let peer = try await SCWPeerConnection.pair(payload)   // once, from the scanned QR
/// let base = try await peer.start()                      // http://127.0.0.1:<port>
/// let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/users"))
/// ```
public final class SCWPeerConnection: Sendable {
    private static let deviceKeyName = "p2p.device-key"

    public let hostFingerprint: String
    private let record: NIOLockedValueBox<PeerRecord>
    private let storage: TunnelSecretStorage
    private let deviceKey: Curve25519.Signing.PrivateKey
    private struct Running {
        var client: SSHTunnelClient
        let proxy: LoopbackProxy
        let group: MultiThreadedEventLoopGroup
        var supervisor: Task<Void, Never>?
        var pathWatcher: Task<Void, Never>?
    }

    private let running = NIOLockedValueBox<Running?>(nil)
    private let route = NIOLockedValueBox<PeerRoute?>(nil)
    /// How long each connection step waits; see `P2PTimeouts`.
    public let timeouts: P2PTimeouts
    /// Where network changes come from (replaced in tests).
    let pathSource = NIOLockedValueBox<any NetworkPathSource>(SystemPathSource())
    /// Whether there is a network at all, and a counter that moves whenever that changes or the network is replaced, so a
    /// reconnection that is waiting can start at once.
    private let network = NIOLockedValueBox<(online: Bool, epoch: Int)>((true, 0))
    /// Routes `start()` must not try (tests that need to prove a specific one).
    let skippedRoutes = NIOLockedValueBox<Set<PeerRoute>>([])

    private init(hostFingerprint: String, record: PeerRecord, deviceKey: Curve25519.Signing.PrivateKey, storage: TunnelSecretStorage, timeouts: P2PTimeouts = .default) {
        self.timeouts = timeouts
        self.hostFingerprint = hostFingerprint
        self.record = NIOLockedValueBox(record)
        self.storage = storage
        self.deviceKey = deviceKey
    }

    /// The label the host gave itself in the pairing payload.
    public var name: String? { record.withLockedValue { $0.name } }

    /// Pairs this device with the host in `payload`, remembering it in `storage`, and returns the connection.
    /// Fails with `TunnelError.untrustedHostKey` when the host's key is not the one in the payload, and with
    /// `TunnelError.authenticationRefused` when the token is wrong, used or expired.
    public static func pair(_ payload: PairingPayload, storage: TunnelSecretStorage = KeychainTunnelStorage()) async throws -> SCWPeerConnection {
        let deviceKey = try loadOrCreateDeviceKey(storage)
        let seenHostKey = NIOLockedValueBox<NIOSSHPublicKey?>(nil)
        let expected = payload.hostKeyFingerprint
        let client = SSHTunnelClient()
        do {
            try await client.connect(host: payload.host, port: payload.port, key: deviceKey, credential: .pairing(token: payload.token)) { key in
                guard TunnelFingerprint.of(key) == expected else { return false }
                seenHostKey.withLockedValue { $0 = key }
                return true
            }
        } catch {
            await client.close()
            throw error
        }
        await client.close()
        guard let hostKey = seenHostKey.withLockedValue({ $0 }) else { throw TunnelError.untrustedHostKey }

        let record = PeerRecord(host: payload.host, port: payload.port, appPort: payload.appPort, hostKey: String(openSSHPublicKey: hostKey), name: payload.name, rendezvous: payload.rendezvous?.absoluteString)
        guard let text = try String(data: JSONEncoder().encode(record), encoding: .utf8), storage.write(text, forKey: recordName(expected)) else {
            throw TunnelError.storageUnavailable
        }
        return SCWPeerConnection(hostFingerprint: expected, record: record, deviceKey: deviceKey, storage: storage)
    }

    /// The hosts announcing themselves on the local network, for a device that pairs by typing a code (no camera).
    public static func discoverHosts(timeout: TimeInterval = 3) async -> [DiscoveredHost] {
        await PeerDiscovery.browse(timeout: timeout)
    }

    /// Pairs with `host` using the six-digit code its screen shows, without a scanned QR code. The host key does not arrive
    /// out of band here, so before anything secret is sent `confirm` receives the short fingerprint of the key the host
    /// really presents: show it and let the user compare it with the one on the host's screen. Only if `confirm` returns
    /// `true` is the code sent, and only to that key. Fails with `TunnelError.untrustedHostKey` when it returns `false` or
    /// when the host answers with another key the second time.
    public static func pair(
        code: String, with host: DiscoveredHost, rendezvous: URL? = nil, storage: TunnelSecretStorage = KeychainTunnelStorage(),
        confirm: @escaping @Sendable (_ shortFingerprint: String) async -> Bool
    ) async throws -> SCWPeerConnection {
        let deviceKey = try loadOrCreateDeviceKey(storage)
        // First connection: only to see the host key. It is refused after the key exchange, before any credential is sent, so
        // the user can take as long as they need to compare fingerprints without a handshake deadline running.
        let seenHostKey = NIOLockedValueBox<NIOSSHPublicKey?>(nil)
        let probe = SSHTunnelClient()
        do {
            try await probe.connect(host: host.host, port: host.port, key: deviceKey, credential: .pairing(token: code)) { key in
                seenHostKey.withLockedValue { $0 = key }
                return false
            }
        } catch {
            // Expected: `untrustedHostKey`, having learned the key.
        }
        await probe.close()
        guard let hostKey = seenHostKey.withLockedValue({ $0 }) else { throw TunnelError.notConnected }
        guard await confirm(TunnelFingerprint.short(TunnelFingerprint.of(hostKey))) else { throw TunnelError.untrustedHostKey }

        // Second connection: pinned to the key the user confirmed; the code goes only to that key.
        let client = SSHTunnelClient()
        do {
            try await client.connect(host: host.host, port: host.port, key: deviceKey, credential: .pairing(token: code)) { $0 == hostKey }
        } catch {
            await client.close()
            throw error
        }
        await client.close()
        let fingerprint = TunnelFingerprint.of(hostKey)
        let record = PeerRecord(host: host.host, port: host.port, appPort: host.appPort, hostKey: String(openSSHPublicKey: hostKey), name: host.name, rendezvous: rendezvous?.absoluteString)
        guard let text = try String(data: JSONEncoder().encode(record), encoding: .utf8), storage.write(text, forKey: recordName(fingerprint)) else {
            throw TunnelError.storageUnavailable
        }
        return SCWPeerConnection(hostFingerprint: fingerprint, record: record, deviceKey: deviceKey, storage: storage)
    }

    /// Opens a connection to a host paired earlier. Throws `TunnelError.pairingFailed` if `hostFingerprint` is unknown.
    public convenience init(hostFingerprint: String, storage: TunnelSecretStorage = KeychainTunnelStorage(), timeouts: P2PTimeouts = .default) throws {
        guard let text = storage.read(Self.recordName(hostFingerprint)), let data = text.data(using: .utf8),
              let record = try? JSONDecoder().decode(PeerRecord.self, from: data) else { throw TunnelError.pairingFailed }
        // A paired host implies a stored device key: without it the host would refuse this device, so fail here.
        guard storage.read(Self.deviceKeyName) != nil else { throw TunnelError.pairingFailed }
        self.init(hostFingerprint: hostFingerprint, record: record, deviceKey: try Self.loadOrCreateDeviceKey(storage), storage: storage, timeouts: timeouts)
    }

    /// Connects to the host and starts the loopback listener; returns its base URL. A new call restarts the connection.
    /// When the stored address no longer answers, the host is looked up on the local network by its announced fingerprint
    /// and the new address is remembered, and failing that it is reached through the relay. Once started, the connection
    /// is kept: if it drops (the network changed, the host restarted) it is re-established on the same URL, which then
    /// fails requests only for the moments in between. The listener is on `127.0.0.1` and is not authenticated: any local
    /// process that knows the port can use this device's tunnel, so keep the URL inside the app.
    public func start() async throws -> URL {
        await stop()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client: SSHTunnelClient
        do {
            let (connected, via) = try await establish(group: group)
            client = connected
            route.withLockedValue { $0 = via }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        let proxy = LoopbackProxy(client: client, destination: TunnelAllowList(port: record.withLockedValue { $0.appPort }))
        let port: Int
        do { port = try await proxy.start() } catch {
            await client.close()
            try? await group.shutdownGracefully()
            throw error
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)") else { throw TunnelError.notConnected }
        running.withLockedValue { $0 = Running(client: client, proxy: proxy, group: group, supervisor: nil) }
        let supervisor = Task { [weak self] in
            guard let self else { return }
            await self.keepConnected(proxy: proxy, group: group)
        }
        let watcher = Task { [weak self] in
            guard let self else { return }
            await self.watchNetwork()
        }
        running.withLockedValue { $0?.supervisor = supervisor; $0?.pathWatcher = watcher }
        return url
    }

    /// How the connection reached the host the last time it was established; `nil` before `start()` and after `stop()`.
    public var currentRoute: PeerRoute? { route.withLockedValue { $0 } }

    /// Reaches the host the best way available: the stored address, the local network search, the relay.
    private func establish(group: MultiThreadedEventLoopGroup) async throws -> (SSHTunnelClient, PeerRoute) {
        let known = record.withLockedValue { $0 }
        var failure: Error
        do {
            return (try await connect(to: known, group: group), .local)
        } catch {
            // Only an address that does not answer is worth a search: a refusal (revoked device, wrong key) would repeat anywhere.
            // A different key at this address says nothing about where the host is now, so the search goes on.
            if let refusal = error as? TunnelError, refusal == .authenticationRefused || refusal == .tooManyConnections { throw error }
            failure = error
        }
        if !skippedRoutes.withLockedValue({ $0.contains(.discovered) }), let client = await rediscover(known, group: group, failure: &failure) {
            return (client, .discovered)
        }
        if let reached = await viaRendezvous(known, group: group, failure: &failure) { return reached }
        throw failure
    }

    /// Re-establishes the connection whenever it ends, until `stop()` or until the host refuses this device. Waits while there
    /// is no network, and starts again at once when the network comes back or changes.
    private func keepConnected(proxy: LoopbackProxy, group: MultiThreadedEventLoopGroup) async {
        var delay: TimeInterval = 1
        while !Task.isCancelled {
            guard let current = running.withLockedValue({ $0?.client }) else { return }
            await current.waitUntilClosed()
            guard !Task.isCancelled else { return }
            await current.close()
            while !Task.isCancelled {
                if await pause(for: delay) { delay = 1 } // the network changed while waiting: no reason to keep backing off
                while !network.withLockedValue({ $0.online }), !Task.isCancelled { try? await Task.sleep(nanoseconds: 250_000_000) }
                guard !Task.isCancelled else { return }
                do {
                    let (client, via) = try await establish(group: group)
                    guard !Task.isCancelled, running.withLockedValue({ state -> Bool in state?.client = client; return state != nil }) else {
                        await client.close()
                        return
                    }
                    proxy.replace(client: client)
                    route.withLockedValue { $0 = via }
                    delay = 1
                    break
                } catch {
                    if error as? TunnelError == .authenticationRefused { return } // revoked or wrong key: waiting will not help
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    /// Sleeps for `seconds`, or until the network changes; `true` when it was cut short by a change.
    private func pause(for seconds: TimeInterval) async -> Bool {
        let start = network.withLockedValue { $0.epoch }
        var waited: TimeInterval = 0
        while waited < seconds, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
            if network.withLockedValue({ $0.epoch }) != start { return true }
        }
        return false
    }

    /// Follows the network: no attempts while it is gone, an immediate one when it is back, and a reconnection when packets
    /// now leave through another kind of interface (Wi-Fi to cellular), without waiting for the keepalive to notice.
    private func watchNetwork() async {
        var tracker = NetworkPathTracker()
        for await path in pathSource.withLockedValue({ $0 }).updates() {
            guard !Task.isCancelled else { return }
            switch tracker.observe(path) {
            case .none: break
            case .lost:
                network.withLockedValue { $0.online = false }
            case .restored:
                network.withLockedValue { state in state.online = true; state.epoch += 1 }
            case .rerouted:
                network.withLockedValue { $0.epoch += 1 }
                await running.withLockedValue { $0?.client }?.close() // the supervisor reconnects
            }
        }
    }

    /// The host moved on the local network: look for it by the fingerprint it announces (Bonjour) and remember the new address.
    private func rediscover(_ known: PeerRecord, group: MultiThreadedEventLoopGroup, failure: inout Error) async -> SSHTunnelClient? {
        var rejected: Set<String> = [known.host]
        for _ in 0..<3 {
            guard !Task.isCancelled, let found = await PeerDiscovery.find(fingerprint: hostFingerprint, excluding: rejected) else { return nil }
            var moved = known
            moved.host = found.host
            moved.port = found.port
            do {
                let client = try await connect(to: moved, group: group)
                record.withLockedValue { $0 = moved }
                if let data = try? JSONEncoder().encode(moved), let text = String(data: data, encoding: .utf8) {
                    storage.write(text, forKey: Self.recordName(hostFingerprint))
                }
                return client
            } catch {
                failure = error
                rejected.insert(found.host)
            }
        }
        return nil
    }

    /// Not on the same network: knock at the rendezvous, so the host lets this device in, then reach it. First directly, by
    /// both sides opening a TCP connection to the other at the same time (this device announces the public address its NAT
    /// gave the socket, the host announces its own); if that does not work within a few seconds, through the relay address
    /// the host published. The addresses change between runs of the host, so none is remembered.
    private func viaRendezvous(_ known: PeerRecord, group: MultiThreadedEventLoopGroup, failure: inout Error) async -> (SSHTunnelClient, PeerRoute)? {
        guard let text = known.rendezvous, let base = URL(string: text) else { return nil }
        let rendezvous = RendezvousClient(baseURL: base)

        // Where this device looks from the outside, from a port it will also connect from.
        var punch: (port: Int, mine: RendezvousRecord.Candidate)?
        if !skippedRoutes.withLockedValue({ $0.contains(.direct) }),
           let stuns = (try? await rendezvous.candidates(hostFingerprint: hostFingerprint))?.filter({ $0.kind == "stun" }), !stuns.isEmpty,
           let port = await Self.freePort(group: group) {
            switch await NATProbe.mapping(servers: stuns.map { ($0.host, $0.port) }, localPort: port, group: group, timeout: timeouts.stunAmount) {
            case .stable(let host, let mapped), .unknown(let host, let mapped): punch = (port, .init(kind: "direct", host: host, port: mapped))
            case .symmetric, .unreachable: break // a direct connection cannot work: straight to the relay
            }
        }
        do { try await rendezvous.knock(hostFingerprint: hostFingerprint, deviceKey: deviceKey, candidate: punch?.mine) } catch {
            failure = error
            return nil
        }
        var directTried = false
        for round in 0..<4 {
            // The host reads its knocks every couple of seconds.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return nil }
            let candidates: [RendezvousRecord.Candidate]?
            do { candidates = try await rendezvous.candidates(hostFingerprint: hostFingerprint) } catch {
                failure = error
                continue
            }
            if let punch, round < 2, let direct = candidates?.first(where: { $0.kind == "direct" }) {
                directTried = true
                var target = known
                target.host = direct.host
                target.port = direct.port
                let deadline = Date().addingTimeInterval(timeouts.directWindow)
                while Date() < deadline, !Task.isCancelled {
                    do { return (try await connect(to: target, group: group, localPort: punch.port, wideArea: true, connectTimeout: .seconds(2)), .direct) } catch {
                        failure = error
                        if error as? TunnelError == .authenticationRefused { return nil }
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
            }
            for candidate in candidates ?? [] where candidate.kind == "relay" {
                var target = known
                target.host = candidate.host
                target.port = candidate.port
                do { return (try await connect(to: target, group: group, wideArea: true), .relay) } catch {
                    failure = error
                    if error as? TunnelError == .authenticationRefused { return nil } // refused (revoked, wrong key): retrying cannot change it
                }
            }
        }
        if directTried { failure = TunnelError.directConnectionFailed } // the direct attempt and then the relay (if any) both failed
        return nil
    }

    /// A TCP port that is free right now and may be shared (the connection and the address lookup leave from the same one).
    private static func freePort(group: EventLoopGroup) async -> Int? {
        guard let channel = try? await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseport), value: 1)
            .bind(host: "0.0.0.0", port: 0).get() else { return nil }
        let port = channel.localAddress?.port
        try? await channel.close()
        return port
    }

    private func connect(to target: PeerRecord, group: MultiThreadedEventLoopGroup, localPort: Int? = nil, wideArea: Bool = false, connectTimeout: TimeAmount? = nil) async throws -> SSHTunnelClient {
        let pinned = try NIOSSHPublicKey(openSSHPublicKey: target.hostKey)
        let client = SSHTunnelClient(group: group)
        do {
            try await client.connect(host: target.host, port: target.port, key: deviceKey, credential: .key, localPort: localPort,
                                 connectTimeout: connectTimeout ?? (wideArea ? timeouts.wideAreaConnectAmount : timeouts.localConnectAmount),
                                 handshakeTimeout: .milliseconds(Int64((wideArea ? timeouts.wideAreaHandshake : timeouts.localHandshake) * 1000))) { $0 == pinned }
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    /// Closes the SSH connection the way a network change would (tests): the supervisor then reconnects.
    func dropConnection() async {
        await running.withLockedValue { $0?.client }?.close()
    }

    public func stop() async {
        route.withLockedValue { $0 = nil }
        guard let current = running.withLockedValue({ $0.take() }) else { return }
        current.supervisor?.cancel()
        current.pathWatcher?.cancel()
        await current.client.close() // also wakes the supervisor, which waits for this connection to end
        await current.supervisor?.value
        await current.pathWatcher?.value
        await current.proxy.stop()
        try? await current.group.shutdownGracefully()
    }

    private static func recordName(_ fingerprint: String) -> String { "p2p.host.\(fingerprint)" }

    private static func loadOrCreateDeviceKey(_ storage: TunnelSecretStorage) throws -> Curve25519.Signing.PrivateKey {
        if let stored = storage.read(deviceKeyName) {
            guard let raw = Data(base64Encoded: stored), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { throw TunnelError.corruptedStorage }
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        guard storage.write(key.rawRepresentation.base64EncodedString(), forKey: deviceKeyName) else { throw TunnelError.storageUnavailable }
        return key
    }
}

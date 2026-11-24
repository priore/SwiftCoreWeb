// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation
import NIOConcurrencyHelpers
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
        let supervisor: Task<Void, Never>?
    }

    private let running = NIOLockedValueBox<Running?>(nil)
    private let route = NIOLockedValueBox<PeerRoute?>(nil)
    /// Routes `start()` must not try (tests that need to prove a specific one).
    let skippedRoutes = NIOLockedValueBox<Set<PeerRoute>>([])

    private init(hostFingerprint: String, record: PeerRecord, deviceKey: Curve25519.Signing.PrivateKey, storage: TunnelSecretStorage) {
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

    /// Opens a connection to a host paired earlier. Throws `TunnelError.pairingFailed` if `hostFingerprint` is unknown.
    public convenience init(hostFingerprint: String, storage: TunnelSecretStorage = KeychainTunnelStorage()) throws {
        guard let text = storage.read(Self.recordName(hostFingerprint)), let data = text.data(using: .utf8),
              let record = try? JSONDecoder().decode(PeerRecord.self, from: data) else { throw TunnelError.pairingFailed }
        // A paired host implies a stored device key: without it the host would refuse this device, so fail here.
        guard storage.read(Self.deviceKeyName) != nil else { throw TunnelError.pairingFailed }
        self.init(hostFingerprint: hostFingerprint, record: record, deviceKey: try Self.loadOrCreateDeviceKey(storage), storage: storage)
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
        let supervisor = Task { [weak self] in
            guard let self else { return }
            await self.keepConnected(proxy: proxy, group: group)
        }
        running.withLockedValue { $0 = Running(client: client, proxy: proxy, group: group, supervisor: supervisor) }
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
            switch error {
            case TunnelError.notConnected: break
            case is TunnelError: throw error
            default: break
            }
            failure = error
        }
        if !skippedRoutes.withLockedValue({ $0.contains(.discovered) }), let client = await rediscover(known, group: group, failure: &failure) {
            return (client, .discovered)
        }
        if let client = await viaRelay(known, group: group, failure: &failure) { return (client, .relay) }
        throw failure
    }

    /// Re-establishes the connection whenever it ends, until `stop()` or until the host refuses this device.
    private func keepConnected(proxy: LoopbackProxy, group: MultiThreadedEventLoopGroup) async {
        var delay: UInt64 = 1_000_000_000
        while !Task.isCancelled {
            guard let current = running.withLockedValue({ $0?.client }) else { return }
            await current.waitUntilClosed()
            guard !Task.isCancelled else { return }
            await current.close()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                do {
                    let (client, via) = try await establish(group: group)
                    guard !Task.isCancelled, running.withLockedValue({ state -> Bool in state?.client = client; return state != nil }) else {
                        await client.close()
                        return
                    }
                    proxy.replace(client: client)
                    route.withLockedValue { $0 = via }
                    delay = 1_000_000_000
                    break
                } catch {
                    if let refusal = error as? TunnelError, refusal != .notConnected { return } // revoked or wrong key: waiting will not help
                    delay = min(delay * 2, 30_000_000_000)
                }
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

    /// Not on the same network: knock at the rendezvous, so the host lets this device through its relay, then connect to the
    /// relayed address the host published. The relayed address changes between runs of the host, so it is not remembered.
    private func viaRelay(_ known: PeerRecord, group: MultiThreadedEventLoopGroup, failure: inout Error) async -> SSHTunnelClient? {
        guard let text = known.rendezvous, let base = URL(string: text) else { return nil }
        let rendezvous = RendezvousClient(baseURL: base)
        do { try await rendezvous.knock(hostFingerprint: hostFingerprint, deviceKey: deviceKey) } catch {
            failure = error
            return nil
        }
        for _ in 0..<4 {
            // The host reads its knocks every couple of seconds.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return nil }
            let candidates: [RendezvousRecord.Candidate]?
            do { candidates = try await rendezvous.candidates(hostFingerprint: hostFingerprint) } catch {
                failure = error
                continue
            }
            for candidate in candidates ?? [] where candidate.kind == "relay" {
                var target = known
                target.host = candidate.host
                target.port = candidate.port
                do { return try await connect(to: target, group: group) } catch {
                    failure = error
                    if let refusal = error as? TunnelError, refusal != .notConnected { return nil } // refused (revoked, wrong key): retrying cannot change it
                }
            }
        }
        return nil
    }

    private func connect(to target: PeerRecord, group: MultiThreadedEventLoopGroup) async throws -> SSHTunnelClient {
        let pinned = try NIOSSHPublicKey(openSSHPublicKey: target.hostKey)
        let client = SSHTunnelClient(group: group)
        do {
            try await client.connect(host: target.host, port: target.port, key: deviceKey, credential: .key) { $0 == pinned }
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
        await current.client.close() // also wakes the supervisor, which waits for this connection to end
        await current.supervisor?.value
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

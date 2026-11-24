// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation
import NIOConcurrencyHelpers
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
    private let running = NIOLockedValueBox<(client: SSHTunnelClient, proxy: LoopbackProxy)?>(nil)

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

        let record = PeerRecord(host: payload.host, port: payload.port, appPort: payload.appPort, hostKey: String(openSSHPublicKey: hostKey), name: payload.name)
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
    /// and the new address is remembered. The listener is on `127.0.0.1` and is not authenticated: any local process that
    /// knows the port can use this device's tunnel, so keep the URL inside the app.
    public func start() async throws -> URL {
        await stop()
        let known = record.withLockedValue { $0 }
        do {
            return try await connect(to: known)
        } catch {
            // Only an address that does not answer is worth a search: a refusal (revoked device, wrong key) would repeat anywhere.
            switch error {
            case TunnelError.notConnected: break
            case is TunnelError: throw error
            default: break
            }
            var rejected: Set<String> = [known.host]
            var lastError = error
            for _ in 0..<3 {
                guard !Task.isCancelled, let found = await PeerDiscovery.find(fingerprint: hostFingerprint, excluding: rejected) else { throw lastError }
                var moved = known
                moved.host = found.host
                moved.port = found.port
                do {
                    let url = try await connect(to: moved)
                    record.withLockedValue { $0 = moved }
                    if let data = try? JSONEncoder().encode(moved), let text = String(data: data, encoding: .utf8) {
                        storage.write(text, forKey: Self.recordName(hostFingerprint))
                    }
                    return url
                } catch {
                    lastError = error
                    rejected.insert(found.host)
                }
            }
            throw lastError
        }
    }

    private func connect(to target: PeerRecord) async throws -> URL {
        let pinned = try NIOSSHPublicKey(openSSHPublicKey: target.hostKey)
        let client = SSHTunnelClient()
        do {
            try await client.connect(host: target.host, port: target.port, key: deviceKey, credential: .key) { $0 == pinned }
            let proxy = LoopbackProxy(client: client, destination: TunnelAllowList(port: target.appPort))
            let port = try await proxy.start()
            running.withLockedValue { $0 = (client, proxy) }
            guard let url = URL(string: "http://127.0.0.1:\(port)") else { throw TunnelError.notConnected }
            return url
        } catch {
            await client.close()
            throw error
        }
    }

    public func stop() async {
        guard let current = running.withLockedValue({ $0.take() }) else { return }
        await current.proxy.stop()
        await current.client.close()
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

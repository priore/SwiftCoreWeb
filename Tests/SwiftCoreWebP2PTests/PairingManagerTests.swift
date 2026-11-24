// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import Crypto
import NIOConcurrencyHelpers
import NIOSSH
@testable import SwiftCoreWebP2P

final class PairingManagerTests: XCTestCase {
    private func deviceKey() -> NIOSSHPublicKey { NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey }

    /// Computed independently (Python: OpenSSH wire format of the Ed25519 key built from 32 x 0x01, then SHA-256, unpadded base64).
    func testFingerprintMatchesTheOpenSSHForm() throws {
        let key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))).publicKey
        XCTAssertEqual(String(openSSHPublicKey: key), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c")
        XCTAssertEqual(TunnelFingerprint.of(key), "SHA256:fe85JkIjo8VPe+XqXJGH5Mau1EMFdK1OdKvJUFicyA8")
    }

    func testHostKeyAndDevicesSurviveARestart() throws {
        let storage = InMemoryTunnelStorage()
        let first = try PairingManager(storage: storage)
        let token = first.openPairing()
        let device = deviceKey()
        XCTAssertTrue(first.attemptPairing(device: device, token: token))

        let second = try PairingManager(storage: storage)
        XCTAssertEqual(second.hostFingerprint, first.hostFingerprint)
        XCTAssertEqual(second.devices.map(\.id), [TunnelFingerprint.of(device)])
        XCTAssertNotNil(second.device(for: device))
        XCTAssertNil(second.device(for: deviceKey()))
    }

    func testTokenIsOneTimeAndEndsTheSession() throws {
        let manager = try PairingManager(storage: InMemoryTunnelStorage())
        let token = manager.openPairing()
        XCTAssertTrue(manager.isPairingOpen)
        XCTAssertTrue(manager.attemptPairing(device: deviceKey(), token: token))
        XCTAssertFalse(manager.isPairingOpen)
        XCTAssertFalse(manager.attemptPairing(device: deviceKey(), token: token)) // reuse
    }

    func testWrongTokensUseUpAttemptsAndCloseTheSession() throws {
        let manager = try PairingManager(storage: InMemoryTunnelStorage())
        let token = manager.openPairing(maxAttempts: 3)
        for _ in 0..<3 { XCTAssertFalse(manager.attemptPairing(device: deviceKey(), token: "wrong")) }
        XCTAssertFalse(manager.isPairingOpen)
        XCTAssertFalse(manager.attemptPairing(device: deviceKey(), token: token)) // the right token is too late
        XCTAssertTrue(manager.devices.isEmpty)
    }

    func testExpiredSessionIsRefused() throws {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000_000))
        let manager = try PairingManager(storage: InMemoryTunnelStorage(), now: { clock.withLockedValue { $0 } })
        let token = manager.openPairing(validFor: 60)
        XCTAssertNotNil(manager.payload(host: "h", port: 1, appPort: 2))
        clock.withLockedValue { $0.addTimeInterval(61) }
        XCTAssertFalse(manager.isPairingOpen)
        XCTAssertNil(manager.payload(host: "h", port: 1, appPort: 2))
        XCTAssertFalse(manager.attemptPairing(device: deviceKey(), token: token))
    }

    func testRevokeRemovesTheDeviceAndNotifiesTheServer() throws {
        let manager = try PairingManager(storage: InMemoryTunnelStorage())
        let revoked = NIOLockedValueBox<[String]>([])
        manager.setRevocationHandler { id in revoked.withLockedValue { $0.append(id) } }
        let device = deviceKey()
        XCTAssertTrue(manager.attemptPairing(device: device, token: manager.openPairing()))
        let id = TunnelFingerprint.of(device)

        XCTAssertTrue(manager.revoke(deviceID: id))
        XCTAssertNil(manager.device(for: device))
        XCTAssertEqual(revoked.withLockedValue { $0 }, [id])
        XCTAssertFalse(manager.revoke(deviceID: id)) // already gone: no second notification
        XCTAssertEqual(revoked.withLockedValue { $0.count }, 1)
    }

    func testPayloadRoundTripAndRejectsIncompleteLinks() throws {
        let manager = try PairingManager(storage: InMemoryTunnelStorage())
        manager.openPairing()
        let payload = try XCTUnwrap(manager.payload(host: "192.168.1.5", port: 2222, appPort: 8080, name: "Mac salotto"))
        XCTAssertEqual(PairingPayload(payload.url.absoluteString), payload)
        XCTAssertEqual(payload.hostKeyFingerprint, manager.hostFingerprint)

        for broken in ["", "http://h:1?sp=1&t=a&fp=b", "scw-p2p://h?sp=1&t=a&fp=b", "scw-p2p://h:1?t=a&fp=b", "scw-p2p://h:1?sp=1&fp=b", "scw-p2p://h:1?sp=1&t=a"] {
            XCTAssertNil(PairingPayload(broken), broken)
        }
    }

    func testStorageThatRefusesTheHostKeyFailsLoudly() {
        struct Refusing: TunnelSecretStorage {
            func read(_ key: String) -> String? { nil }
            func write(_ value: String, forKey key: String) -> Bool { false }
        }
        XCTAssertThrowsError(try PairingManager(storage: Refusing())) { XCTAssertEqual($0 as? TunnelError, .storageUnavailable) }
    }
}

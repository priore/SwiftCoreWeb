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

        XCTAssertTrue(try manager.revoke(deviceID: id))
        XCTAssertNil(manager.device(for: device))
        XCTAssertEqual(revoked.withLockedValue { $0 }, [id])
        XCTAssertFalse(try manager.revoke(deviceID: id)) // already gone: no second notification
        XCTAssertEqual(revoked.withLockedValue { $0.count }, 1)
    }

    func testPayloadRoundTripIncludingIPv6AndAwkwardNames() throws {
        let manager = try PairingManager(storage: InMemoryTunnelStorage())
        manager.openPairing()
        for (host, name) in [("192.168.1.5", "Mac salotto"), ("fe80::1", "a&b=c+d #1"), ("mac.local", nil)] {
            let payload = try XCTUnwrap(manager.payload(host: host, port: 2222, appPort: 8080, name: name))
            XCTAssertEqual(PairingPayload(payload.link), payload, host)
            XCTAssertEqual(payload.hostKeyFingerprint, manager.hostFingerprint)
        }
        XCTAssertFalse(try XCTUnwrap(manager.payload(host: "h", port: 1, appPort: 2)).description.contains(try XCTUnwrap(manager.payload(host: "h", port: 1, appPort: 2)).token))
    }

    func testPayloadRefusesBadHostsPortsAndMalformedLinks() throws {
        XCTAssertNil(PairingPayload(host: "a b", port: 1, appPort: 2, token: "t", hostKeyFingerprint: "f"))
        XCTAssertNil(PairingPayload(host: "", port: 1, appPort: 2, token: "t", hostKeyFingerprint: "f"))
        XCTAssertNil(PairingPayload(host: "h", port: -1, appPort: 2, token: "t", hostKeyFingerprint: "f"))
        XCTAssertNil(PairingPayload(host: "h", port: 1, appPort: 70_000, token: "t", hostKeyFingerprint: "f"))
        XCTAssertNotNil(PairingPayload("SCW-P2P://h:1?sp=2&t=a&fp=b")) // the scheme is case-insensitive
        for broken in ["", "http://h:1?sp=1&t=a&fp=b", "scw-p2p://h?sp=1&t=a&fp=b", "scw-p2p://h:1?t=a&fp=b", "scw-p2p://h:1?sp=1&fp=b",
                       "scw-p2p://h:1?sp=1&t=a", "scw-p2p://h:0?sp=1&t=a&fp=b", "scw-p2p://h:1?sp=99999&t=a&fp=b", "scw-p2p://h:1?sp=-5&t=a&fp=b",
                       "scw-p2p://h:1?sp=+80&t=a&fp=b", "scw-p2p://h:1?sp=1&t=a&t=b&fp=b"] {
            XCTAssertNil(PairingPayload(broken), broken)
        }
    }

    func testConcurrentValidAttemptsRegisterExactlyOneDevice() throws {
        let manager = try PairingManager(storage: InMemoryTunnelStorage())
        let token = manager.openPairing()
        let wins = NIOLockedValueBox(0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if manager.attemptPairing(device: deviceKey(), token: token) { wins.withLockedValue { $0 += 1 } }
        }
        XCTAssertEqual(wins.withLockedValue { $0 }, 1)
        XCTAssertEqual(manager.devices.count, 1)
    }

    /// A storage that works until told to fail, to see what a failing Keychain does to state.
    private final class FlakyStorage: TunnelSecretStorage {
        private let inner = InMemoryTunnelStorage()
        let failing = NIOLockedValueBox(false)
        func read(_ key: String) -> String? { inner.read(key) }
        func write(_ value: String, forKey key: String) -> Bool { failing.withLockedValue { $0 } ? false : inner.write(value, forKey: key) }
    }

    func testPairingThatCannotBeSavedIsNotGrantedAndFailedRevokeThrows() throws {
        let storage = FlakyStorage()
        let manager = try PairingManager(storage: storage)
        let paired = deviceKey()
        XCTAssertTrue(manager.attemptPairing(device: paired, token: manager.openPairing()))

        storage.failing.withLockedValue { $0 = true }
        let other = deviceKey()
        XCTAssertFalse(manager.attemptPairing(device: other, token: manager.openPairing()))
        XCTAssertNil(manager.device(for: other)) // not granted in memory either
        XCTAssertFalse(manager.rename(deviceID: TunnelFingerprint.of(paired), to: "x"))
        XCTAssertNotEqual(manager.devices.first?.name, "x")

        let revoked = NIOLockedValueBox(0)
        manager.setRevocationHandler { _ in revoked.withLockedValue { $0 += 1 } }
        XCTAssertThrowsError(try manager.revoke(deviceID: TunnelFingerprint.of(paired))) { XCTAssertEqual($0 as? TunnelError, .storageUnavailable) }
        XCTAssertNil(manager.device(for: paired)) // refused now even though the removal could not be saved
        XCTAssertEqual(revoked.withLockedValue { $0 }, 1) // and its open sessions are dropped
    }

    func testRepairingKeepsNameAndDateAndCorruptStorageIsNeverOverwritten() throws {
        let storage = InMemoryTunnelStorage()
        let manager = try PairingManager(storage: storage)
        let device = deviceKey()
        XCTAssertTrue(manager.attemptPairing(device: device, token: manager.openPairing()))
        XCTAssertTrue(manager.rename(deviceID: TunnelFingerprint.of(device), to: "iPhone di Anna"))
        let before = try XCTUnwrap(manager.devices.first)
        XCTAssertTrue(manager.attemptPairing(device: device, token: manager.openPairing()))
        XCTAssertEqual(manager.devices, [before])

        storage.write("not base64 !", forKey: "p2p.host-key")
        XCTAssertThrowsError(try PairingManager(storage: storage)) { XCTAssertEqual($0 as? TunnelError, .corruptedStorage) }
        XCTAssertEqual(storage.read("p2p.host-key"), "not base64 !") // left as it was
        storage.write("{broken", forKey: "p2p.devices")
        let healthy = InMemoryTunnelStorage()
        healthy.write("{broken", forKey: "p2p.devices")
        XCTAssertThrowsError(try PairingManager(storage: healthy)) { XCTAssertEqual($0 as? TunnelError, .corruptedStorage) }
    }

    func testStorageThatRefusesTheHostKeyFailsLoudly() {
        struct Refusing: TunnelSecretStorage {
            func read(_ key: String) -> String? { nil }
            func write(_ value: String, forKey key: String) -> Bool { false }
        }
        XCTAssertThrowsError(try PairingManager(storage: Refusing())) { XCTAssertEqual($0 as? TunnelError, .storageUnavailable) }
    }
}

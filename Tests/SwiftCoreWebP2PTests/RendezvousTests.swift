// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import Crypto
import NIOSSH
import SwiftCoreWeb
@testable import SwiftCoreWebP2P

final class RendezvousTests: XCTestCase {
    private func startRendezvous(maxHosts: Int = 1000) async throws -> RendezvousClient {
        let port = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        let app = builder.build()
        P2PRendezvous(maxHosts: maxHosts).mount(on: app)
        Task { try? await app.runAsync() }
        for _ in 0..<100 where !app.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        addTeardownBlock { try? await app.stopAsync() }
        return RendezvousClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
    }

    private func identity() -> (key: Curve25519.Signing.PrivateKey, fingerprint: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key, TunnelFingerprint.of(NIOSSHPrivateKey(ed25519Key: key).publicKey))
    }

    func testEnvelopeSignatureAndOpenSSHKeyRoundTrip() throws {
        let (key, fingerprint) = identity()
        let envelope = try SignedEnvelope.sign(Data("hello".utf8), with: key)
        let verified = try XCTUnwrap(envelope.verified())
        XCTAssertEqual(verified.payload, Data("hello".utf8))
        XCTAssertEqual(verified.signerFingerprint, fingerprint)
        let tampered = SignedEnvelope(payload: Data("hellO".utf8).base64EncodedString(), signature: envelope.signature, key: envelope.key)
        XCTAssertNil(tampered.verified())
    }

    func testHostPublishesDeviceFetchesAndKnocks() async throws {
        let rendezvous = try await startRendezvous()
        let host = identity(), device = identity()

        var found = try await rendezvous.candidates(hostFingerprint: host.fingerprint)
        XCTAssertNil(found, "nothing published yet")

        let relay = RendezvousRecord.Candidate(kind: "relay", host: "203.0.113.5", port: 50001)
        try await rendezvous.publish([relay], hostKey: host.key, hostFingerprint: host.fingerprint)
        found = try await rendezvous.candidates(hostFingerprint: host.fingerprint)
        XCTAssertEqual(found, [relay])

        try await rendezvous.knock(hostFingerprint: host.fingerprint, deviceKey: device.key)
        let knocks = try await rendezvous.collectKnocks(hostKey: host.key, hostFingerprint: host.fingerprint)
        XCTAssertEqual(knocks.map(\.deviceFingerprint), [device.fingerprint])
        XCTAssertEqual(knocks.first?.address, "127.0.0.1", "the address the rendezvous saw")
        let again = try await rendezvous.collectKnocks(hostKey: host.key, hostFingerprint: host.fingerprint)
        XCTAssertEqual(again, [], "knocks are read once")
    }

    func testOnlyTheHostCanPublishOrReadItsKnocks() async throws {
        let rendezvous = try await startRendezvous()
        let host = identity(), impostor = identity()
        let relay = RendezvousRecord.Candidate(kind: "relay", host: "198.51.100.1", port: 1)

        // The impostor signs for the host's id with its own key: refused.
        do {
            try await rendezvous.publish([relay], hostKey: impostor.key, hostFingerprint: host.fingerprint)
            XCTFail("must be refused")
        } catch { XCTAssertEqual(error as? RendezvousClient.Failure, .badResponse(status: 400)) }
        do {
            _ = try await rendezvous.collectKnocks(hostKey: impostor.key, hostFingerprint: host.fingerprint)
            XCTFail("must be refused")
        } catch { XCTAssertEqual(error as? RendezvousClient.Failure, .badResponse(status: 400)) }
        let none = try await rendezvous.candidates(hostFingerprint: host.fingerprint)
        XCTAssertNil(none)
    }

    func testARecordForAnotherHostIsNotBelieved() async throws {
        let rendezvous = try await startRendezvous()
        let host = identity(), other = identity()
        try await rendezvous.publish([.init(kind: "relay", host: "198.51.100.2", port: 2)], hostKey: other.key, hostFingerprint: other.fingerprint)
        // A device that pins `host` asks for `host`: the rendezvous has nothing under that id.
        let none = try await rendezvous.candidates(hostFingerprint: host.fingerprint)
        XCTAssertNil(none)
    }

    func testRegistrationsAreBounded() async throws {
        let rendezvous = try await startRendezvous(maxHosts: 2)
        for index in 0..<3 {
            let host = identity()
            let publish = { try await rendezvous.publish([.init(kind: "relay", host: "198.51.100.3", port: index + 1)], hostKey: host.key, hostFingerprint: host.fingerprint) }
            if index < 2 { try await publish() } else {
                do { try await publish(); XCTFail("the third host must be refused") } catch { XCTAssertEqual(error as? RendezvousClient.Failure, .badResponse(status: 503)) }
            }
        }
    }
}

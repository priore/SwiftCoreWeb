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
    private func startRendezvous(maxHosts: Int = 1000, trustForwardedFor: Bool = false) async throws -> RendezvousClient {
        let port = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        let app = builder.build()
        P2PRendezvous(maxHosts: maxHosts, trustForwardedFor: trustForwardedFor).mount(on: app)
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

    /// Posts a signed knock by hand, with a header a proxy would add, and returns the address the host reads back.
    private func knockAddress(trusting: Bool, forwardedFor: String) async throws -> String? {
        let rendezvous = try await startRendezvous(trustForwardedFor: trusting)
        let host = identity(), device = identity()
        try await rendezvous.publish([.init(kind: "relay", host: "198.51.100.7", port: 7)], hostKey: host.key, hostFingerprint: host.fingerprint)
        let knock = RendezvousKnockRequest(hostFingerprint: host.fingerprint, issued: Int(Date().timeIntervalSince1970))
        let envelope = try SignedEnvelope.sign(JSONEncoder().encode(knock), with: device.key)
        var request = URLRequest(url: rendezvous.baseURL.appendingPathComponent("p2p/v1/hosts/\(RendezvousPath.hostID(host.fingerprint))/knocks"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(envelope)
        request.setValue(forwardedFor, forHTTPHeaderField: "X-Forwarded-For")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        return try await rendezvous.collectKnocks(hostKey: host.key, hostFingerprint: host.fingerprint).first?.address
    }

    func testForwardedForIsUsedOnlyWhenTrusted() async throws {
        let trusted = try await knockAddress(trusting: true, forwardedFor: "198.51.100.9, 203.0.113.7")
        XCTAssertEqual(trusted, "203.0.113.7", "the last entry is the one the trusted proxy appended")
        let ignored = try await knockAddress(trusting: false, forwardedFor: "203.0.113.7")
        XCTAssertEqual(ignored, "127.0.0.1", "without the option a header never chooses the address")
    }

    func testKnocksNeedARegisteredHostAndAForgedOneIsDropped() async throws {
        let rendezvous = try await startRendezvous()
        let host = identity(), other = identity(), device = identity()
        do { try await rendezvous.knock(hostFingerprint: host.fingerprint, deviceKey: device.key); XCTFail("host never published") } catch {
            XCTAssertEqual(error as? RendezvousClient.Failure, .badResponse(status: 404))
        }
        try await rendezvous.publish([.init(kind: "relay", host: "198.51.100.7", port: 7)], hostKey: host.key, hostFingerprint: host.fingerprint)
        // A knock the device signed for another host, posted under this host's id: the host must not believe it.
        let forged = RendezvousKnockRequest(hostFingerprint: other.fingerprint, issued: Int(Date().timeIntervalSince1970))
        let envelope = try SignedEnvelope.sign(JSONEncoder().encode(forged), with: device.key)
        var request = URLRequest(url: rendezvous.baseURL.appendingPathComponent("p2p/v1/hosts/\(RendezvousPath.hostID(host.fingerprint))/knocks"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(envelope)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        let knocks = try await rendezvous.collectKnocks(hostKey: host.key, hostFingerprint: host.fingerprint)
        XCTAssertEqual(knocks, [])
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

    func testAnOlderRecordCannotReplaceANewerOne() async throws {
        let rendezvous = try await startRendezvous()
        let host = identity()
        let now = Int(Date().timeIntervalSince1970)
        func put(_ issued: Int, port: Int) async throws -> Int {
            let record = RendezvousRecord(fingerprint: host.fingerprint, issued: issued, candidates: [.init(kind: "relay", host: "198.51.100.9", port: port)])
            var request = URLRequest(url: rendezvous.baseURL.appendingPathComponent("p2p/v1/hosts/\(RendezvousPath.hostID(host.fingerprint))"))
            request.httpMethod = "PUT"
            request.httpBody = try JSONEncoder().encode(SignedEnvelope.sign(JSONEncoder().encode(record), with: host.key))
            return ((try await URLSession.shared.data(for: request)).1 as? HTTPURLResponse)?.statusCode ?? 0
        }
        let fresh = try await put(now, port: 2), replayed = try await put(now - 100, port: 1)
        XCTAssertEqual([fresh, replayed], [204, 409])
        let found = try await rendezvous.candidates(hostFingerprint: host.fingerprint)
        XCTAssertEqual(found?.first?.port, 2)
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

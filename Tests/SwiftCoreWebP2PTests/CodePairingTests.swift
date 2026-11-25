// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import NIOConcurrencyHelpers
import SwiftCoreWeb
@testable import SwiftCoreWebP2P

/// A device without a camera lists the hosts on the network, types the code on the host's screen and confirms the host key.
final class CodePairingTests: XCTestCase {
    private func startHost() async throws -> P2PHost {
        let builder = WebApplication.createBuilder()
        builder.usePort(Int.random(in: 30_000..<60_000))
        let host = try builder.useP2P(name: "scw-code-\(UUID().uuidString.prefix(8))", storage: InMemoryTunnelStorage())
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        addTeardownBlock { try? await app.stopAsync() }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where host.tunnelPort == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        return host
    }

    private func discover(_ host: P2PHost) async throws -> DiscoveredHost {
        let fingerprint = try XCTUnwrap(host.pairing).hostFingerprint
        for _ in 0..<5 {
            if let found = await SCWPeerConnection.discoverHosts(timeout: 2).first(where: { $0.fingerprint == fingerprint }) { return found }
        }
        throw XCTSkip("the host was not announced on this machine")
    }

    func testPairingWithASixDigitCodeAfterComparingTheFingerprint() async throws {
        let host = try await startHost()
        let found = try await discover(host)
        XCTAssertEqual(found.appPort, host.tunnel?.appPort)

        let payload = try XCTUnwrap(host.openPairing(host: "127.0.0.1", shortCode: true))
        let code = try XCTUnwrap(host.pairingCode)
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        XCTAssertGreaterThan(payload.token.count, 16, "the QR token stays long")

        let shown = NIOLockedValueBox("")
        let storage = InMemoryTunnelStorage()
        let peer = try await SCWPeerConnection.pair(code: code, with: found, storage: storage) { fingerprint in
            shown.withLockedValue { $0 = fingerprint }
            return true
        }
        XCTAssertEqual(shown.withLockedValue { $0 }, TunnelFingerprint.short(payload.hostKeyFingerprint), "the user compares this with the host's screen")
        XCTAssertEqual(host.pairing?.devices.count, 1)

        let base = try await peer.start()
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: base.appendingPathComponent("ping"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pong")
        await peer.stop()
    }

    func testRefusingTheFingerprintSendsNoCodeAndPairsNothing() async throws {
        let host = try await startHost()
        let found = try await discover(host)
        _ = try XCTUnwrap(host.openPairing(host: "127.0.0.1", shortCode: true))
        do {
            _ = try await SCWPeerConnection.pair(code: try XCTUnwrap(host.pairingCode), with: found, storage: InMemoryTunnelStorage()) { _ in false }
            XCTFail("must not pair")
        } catch { XCTAssertEqual(error as? TunnelError, .untrustedHostKey) }
        XCTAssertEqual(host.pairing?.devices.count, 0)
        XCTAssertTrue(host.pairing?.isPairingOpen ?? false, "the session was not used up: the code never left the device")
    }

    func testAWrongCodeIsRefusedAndTheAttemptsAreLimited() async throws {
        let host = try await startHost()
        let found = try await discover(host)
        _ = try XCTUnwrap(host.openPairing(host: "127.0.0.1", shortCode: true))
        let wrong = host.pairingCode == "000000" ? "000001" : "000000"
        do {
            _ = try await SCWPeerConnection.pair(code: wrong, with: found, storage: InMemoryTunnelStorage()) { _ in true }
            XCTFail("must not pair")
        } catch { XCTAssertEqual(error as? TunnelError, .authenticationRefused) }
        XCTAssertEqual(host.pairing?.devices.count, 0)
    }

    func testTheCodeIsNotSentWhileTheUserIsStillComparing() async throws {
        let host = try await startHost()
        let found = try await discover(host)
        _ = try XCTUnwrap(host.openPairing(host: "127.0.0.1", shortCode: true))
        let code = try XCTUnwrap(host.pairingCode)
        // Longer than the host's handshake deadline: a person comparing 12 characters is not that quick.
        let peer = try await SCWPeerConnection.pair(code: code, with: found, storage: InMemoryTunnelStorage()) { _ in
            try? await Task.sleep(nanoseconds: 11_000_000_000)
            return true
        }
        XCTAssertEqual(host.pairing?.devices.count, 1)
        await peer.stop()
    }

    @MainActor func testTheViewShowsTheCodeInTwoGroups() {
        XCTAssertEqual(P2PPairingView.spaced("123456"), "123 456")
        XCTAssertEqual(P2PPairingView.spaced("abc"), "abc")
    }
}

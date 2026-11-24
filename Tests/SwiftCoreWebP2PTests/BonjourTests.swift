// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import Network
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftCoreWeb
@testable import SwiftCoreWebP2P

/// Proves the announcement is really registered: a browser on the same machine must see the service.
final class BonjourTests: XCTestCase {
    func testTheTunnelIsAnnouncedAsScwP2P() async throws {
        let appPort = Int.random(in: 30_000..<60_000)
        let name = "scw-test-\(UUID().uuidString.prefix(8))"
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        let host = try builder.useP2P(name: name, storage: InMemoryTunnelStorage())
        let app = builder.build()
        addTeardownBlock { try? await app.stopAsync() }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where host.tunnelPort == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotNil(host.tunnelPort)

        let found = NIOLockedValueBox(false)
        let browser = NWBrowser(for: .bonjour(type: P2PTunnelExtension.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(let serviceName, _, _, _) = result.endpoint, serviceName == name { found.withLockedValue { $0 = true } }
            }
        }
        browser.start(queue: .global())
        defer { browser.cancel() }
        for _ in 0..<100 where !found.withLockedValue({ $0 }) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(found.withLockedValue { $0 }, "the service \(name) was not announced")

        // The announcement owns no socket: an IPv6 client is refused at once, it does not reach a listener that hangs up.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        do {
            let channel = try await ClientBootstrap(group: group).connect(host: "::1", port: try XCTUnwrap(host.tunnelPort)).get()
            try? await channel.close()
            XCTFail("nothing should accept connections over IPv6 on the tunnel port")
        } catch {
            // Refused, not "unreachable" or "no such address": something answered on ::1 and it was nobody.
            XCTAssertTrue(String(describing: error).lowercased().contains("refused"), "\(error)")
        }
    }

    func testAClientFindsTheHostAgainWhenItsStoredAddressIsStale() async throws {
        let appPort = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        let host = try builder.useP2P(name: "scw-find-\(UUID().uuidString.prefix(8))", storage: InMemoryTunnelStorage())
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        addTeardownBlock { try? await app.stopAsync() }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where host.tunnelPort == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        let tunnelPort = try XCTUnwrap(host.tunnelPort)

        let clientStorage = InMemoryTunnelStorage()
        let session = try XCTUnwrap(host.openPairing(host: "127.0.0.1"))
        let paired = try await SCWPeerConnection.pair(session, storage: clientStorage)

        // The host "moved": the remembered address answers nothing.
        let key = "p2p.host.\(paired.hostFingerprint)"
        var record = try JSONDecoder().decode(PeerRecord.self, from: Data(try XCTUnwrap(clientStorage.read(key)).utf8))
        record.port = 1
        clientStorage.write(String(decoding: try JSONEncoder().encode(record), as: UTF8.self), forKey: key)

        let peer = try SCWPeerConnection(hostFingerprint: paired.hostFingerprint, storage: clientStorage)
        let base = try await peer.start()
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: base.appendingPathComponent("ping"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pong")
        await peer.stop()

        let saved = try JSONDecoder().decode(PeerRecord.self, from: Data(try XCTUnwrap(clientStorage.read(key)).utf8))
        XCTAssertEqual(saved.port, tunnelPort, "the rediscovered address is remembered")
    }
}

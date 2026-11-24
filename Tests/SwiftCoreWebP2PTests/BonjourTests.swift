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
            XCTAssertNotNil(error)
        }
    }
}

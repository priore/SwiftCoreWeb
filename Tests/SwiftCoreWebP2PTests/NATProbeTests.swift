// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import NIOCore
import NIOPosix
@testable import SwiftCoreWebP2P

final class NATProbeTests: XCTestCase {
    func testClassifiesTheMappingsTwoServersReport() {
        XCTAssertEqual(NATProbe.classify([]), .unreachable)
        XCTAssertEqual(NATProbe.classify([("203.0.113.5", 4000)]), .unknown(host: "203.0.113.5", port: 4000))
        XCTAssertEqual(NATProbe.classify([("203.0.113.5", 4000), ("203.0.113.5", 4000)]), .stable(host: "203.0.113.5", port: 4000))
        XCTAssertEqual(NATProbe.classify([("203.0.113.5", 4000), ("203.0.113.5", 4001)]), .symmetric, "another port towards the second server")
        XCTAssertEqual(NATProbe.classify([("203.0.113.5", 4000), ("203.0.113.6", 4000)]), .symmetric, "another address towards the second server")
    }

    /// Needs the two local coturn servers (ports 34780 and 34781, see `TURNAllocationTests`); there is no NAT on the loopback,
    /// so both must report the socket's own address.
    func testWithoutANATTheMappingIsStable() async throws {
        for port in [34780, 34781] {
            do { try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(host: "127.0.0.1", port: port).get().close() } catch {
                throw XCTSkip("no STUN server on 127.0.0.1:\(port)")
            }
        }
        let local = Int.random(in: 40_000..<60_000)
        let result = await NATProbe.mapping(servers: [("127.0.0.1", 34780), ("127.0.0.1", 34781)], localPort: local, group: MultiThreadedEventLoopGroup.singleton)
        XCTAssertEqual(result, .stable(host: "127.0.0.1", port: local))
    }
}

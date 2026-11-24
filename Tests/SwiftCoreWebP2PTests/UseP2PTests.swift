// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import SwiftCoreWeb
@testable import SwiftCoreWebP2P

final class UseP2PTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func testUseP2PStartsWithTheServerPairsAndStopsWithIt() async throws {
        let appPort = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        let host = try builder.useP2P(name: "test-host", storage: InMemoryTunnelStorage())
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        XCTAssertNil(host.tunnelPort) // not running yet
        XCTAssertNil(host.openPairing(host: "127.0.0.1", appPort: appPort))

        Task { try await app.runAsync() }
        let started = try await waitUntil { host.tunnelPort != nil }
        XCTAssertTrue(started)
        let payload = try XCTUnwrap(host.openPairing(host: "127.0.0.1", appPort: appPort, name: "Test"))
        XCTAssertEqual(payload.appPort, appPort)

        let peer = try await SCWPeerConnection.pair(payload, storage: InMemoryTunnelStorage())
        let base = try await peer.start()
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: base.appendingPathComponent("ping"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pong")
        await peer.stop()

        // Stopping the server stops the tunnel; starting it again brings the tunnel back and the device is still paired.
        try await app.stopAsync()
        XCTAssertNil(host.tunnelPort)
        Task { try await app.runAsync() }
        let restarted = try await waitUntil { host.tunnelPort != nil }
        XCTAssertTrue(restarted)
        let pong = try await URLSession(configuration: .ephemeral).data(from: try await peer.start().appendingPathComponent("ping")).0
        XCTAssertEqual(String(decoding: pong, as: UTF8.self), "pong") // same tunnel port: the stored address still works
        await peer.stop()
        try await app.stopAsync()
    }

    func testDisabledP2PRunsNothing() async throws {
        let appPort = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        let host = try builder.useP2P(.disable, storage: InMemoryTunnelStorage())
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        Task { try await app.runAsync() }
        let started = try await waitUntil { app.isRunning }
        XCTAssertTrue(started)
        XCTAssertFalse(host.isEnabled)
        XCTAssertNil(host.tunnelPort)
        XCTAssertNil(host.openPairing(host: "127.0.0.1", appPort: appPort))
        try await app.stopAsync()
    }
}
